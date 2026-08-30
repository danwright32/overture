#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"

# The Update button installs whatever commit happens to be checked out, so it cannot fix a copy that is
# behind BECAUSE the checkout is behind. Dan hit the loop on 2026-08-04: he pressed Update, the app
# quit, the installer rebuilt the same commit, the app came back, and the panel said "1m behind" again,
# forever. The checkout was sitting on a feature branch whose content had already been squash-merged.
#
# "What has shipped" is always origin/main (record-shipped-commit.sh reads the remote deliberately), and
# "what is installed" is always the local HEAD, so any checkout that is not on current main reads as
# behind and nothing in the update path could ever resolve it.
#
# The decision is separated from the doing so every branch of it is exercised here, including the ones
# that must REFUSE. A refusal matters more than the happy path: this runs unattended in a Terminal
# window while Dan waits for his app to come back, so it must never quietly build the wrong thing, and
# must never disturb a checkout somebody is working in.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

pass() { echo "ok - $1"; }
fail() {
  echo "FAIL - $1"
  [ -n "${2:-}" ] && echo "  $2"
  FAILURES=$((FAILURES + 1))
}

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/update-sync.sh"

# --- the decision ---
# overture_update_verdict DIRTY ON_MAIN HEAD_IS_UPSTREAM MAIN_CAN_FAST_FORWARD

got="$(overture_update_verdict no yes yes yes)"
[ "${got}" = "ready" ] && pass "a checkout already on the shipped commit just builds" \
  || fail "a checkout already on the shipped commit just builds" "got: ${got}"

got="$(overture_update_verdict no yes no yes)"
[ "${got}" = "sync" ] && pass "on main but behind, it brings the code up first" \
  || fail "on main but behind, it brings the code up first" "got: ${got}"

# #2923. A checkout standing on any branch other than main is REFUSED, and this is the case that used
# to be answered "sync". On 2026-08-17 this moved a working checkout off an in-progress feature branch
# in the middle of a session: a full scripts/test-all.sh run then verified main while everyone believed
# it verified the branch, and that pass was written into a PR body as evidence for code it had never
# compiled. A `git push -u origin <branch>` afterwards pushed main's HEAD at the branch's name and was
# refused only by luck of the ref ordering.
#
# Committed work is not evidence that nobody is here (the incident's branch was clean and committed one
# command earlier), and neither is a branch whose commits are all already in main: the harm is that the
# SHELL moves, so the session's next commit lands on main and its next push aims main at a branch name.
got="$(overture_update_verdict no no no yes)"
[ "${got}" = "refuse:not-on-main" ] && pass "a checkout standing somewhere other than main is refused, never moved" \
  || fail "a checkout standing somewhere other than main is refused, never moved" "got: ${got}"

# The refusal has to beat the fast-forward question, or which of two true things gets asked first
# decides the answer.
got="$(overture_update_verdict no no no no)"
[ "${got}" = "refuse:not-on-main" ] && pass "and is refused for that reason rather than as a diverged main" \
  || fail "and is refused for that reason rather than as a diverged main" "got: ${got}"

# Unsaved work still outranks it: dirty is the older, broader refusal and must not be relabelled.
got="$(overture_update_verdict yes no no yes)"
[ "${got}" = "refuse:work-in-progress" ] && pass "uncommitted work off main is still reported as unsaved work" \
  || fail "uncommitted work off main is still reported as unsaved work" "got: ${got}"

# The one move that remains is the one that moves no branch: main fast-forwarding onto its own remote.
got="$(overture_update_verdict no yes no yes)"
[ "${got}" = "sync" ] && pass "main catching up to its own remote is still allowed" \
  || fail "main catching up to its own remote is still allowed" "got: ${got}"

# Its refusal explains itself in the same plain register as the other two.
got="$(overture_update_reason refuse:not-on-main)"
[ -n "${got}" ] && pass "the not-on-main refusal has a sentence of its own" \
  || fail "the not-on-main refusal has a sentence of its own"
case "${got}" in
  *"unsaved work"*) fail "and is not the unsaved-work sentence wearing a second name" "got: ${got}" ;;
  *) pass "and is not the unsaved-work sentence wearing a second name" ;;
esac

# The refusal that protects a session mid-flight. Uncommitted work means somebody is in here.
got="$(overture_update_verdict yes no no yes)"
[ "${got}" = "refuse:work-in-progress" ] && pass "uncommitted work is refused rather than disturbed" \
  || fail "uncommitted work is refused rather than disturbed" "got: ${got}"

# Dirty beats everything, including a checkout that looks otherwise ready: the safe answer cannot depend
# on which of several true things is checked first.
got="$(overture_update_verdict yes yes yes yes)"
[ "${got}" = "refuse:work-in-progress" ] && pass "uncommitted work is refused even when the commit is already current" \
  || fail "uncommitted work is refused even when the commit is already current" "got: ${got}"

# Local main carrying commits that never reached the remote. Moving it would need a person.
got="$(overture_update_verdict no yes no no)"
[ "${got}" = "refuse:diverged" ] && pass "a local main the remote does not contain is refused" \
  || fail "a local main the remote does not contain is refused" "got: ${got}"

# --- what a refusal says ---
# It is read in a Terminal window by somebody who does not work in terminals, so it has to say what
# happened and what to do, not name a git concept.
got="$(overture_update_reason refuse:work-in-progress)"
case "${got}" in
  *"unsaved work"*|*"in progress"*) pass "the work-in-progress refusal explains itself in plain words" ;;
  *) fail "the work-in-progress refusal explains itself in plain words" "got: ${got}" ;;
esac
got="$(overture_update_reason refuse:diverged)"
[ -n "${got}" ] && pass "the diverged refusal explains itself too" \
  || fail "the diverged refusal explains itself too"

# --- the doing, against real repositories ---

TMP="$(fixture_scratch_dir)"
trap 'rm -rf "${TMP}"' EXIT

# A remote with two commits on main, and a clone. Real git, because the whole point is what happens to
# a working copy, and a stub of git could only confirm what this file already assumes (L52).
make_pair() {
  local name="$1"
  local remote="${TMP}/${name}-remote" clone="${TMP}/${name}"
  rm -rf "${remote}" "${clone}"
  git init --quiet --bare -b main "${remote}"
  git clone --quiet "${remote}" "${clone}" 2>/dev/null
  git -C "${clone}" config user.email t@example.com
  git -C "${clone}" config user.name Test
  echo one > "${clone}/file.txt"
  git -C "${clone}" add file.txt
  git -C "${clone}" commit --quiet -m "first"
  git -C "${clone}" push --quiet -u origin main 2>/dev/null
  echo "${clone}"
}

# Adds a commit to the remote's main that the clone does not have yet.
ship_another() {
  local clone="$1"
  local work="${TMP}/shipper-$$"
  rm -rf "${work}"
  git clone --quiet "$(git -C "${clone}" remote get-url origin)" "${work}" 2>/dev/null
  git -C "${work}" config user.email t@example.com
  git -C "${work}" config user.name Test
  echo two > "${work}/file.txt"
  git -C "${work}" add file.txt
  git -C "${work}" commit --quiet -m "second"
  git -C "${work}" push --quiet origin main 2>/dev/null
  rm -rf "${work}"
}

# 1. #2923: a clean checkout standing on a feature branch, with newer work on the remote. It is left
# EXACTLY where it was found, because moving it is what silently redirected a session's suite run, its
# next commit and its next push in the incident this refusal comes from.
clone="$(make_pair parked)"
git -C "${clone}" checkout --quiet -b some-feature
ship_another "${clone}"
before="$(git -C "${clone}" rev-parse HEAD)"
out="$(overture_bring_checkout_current "${clone}" 2>&1)"
status=$?
branch="$(git -C "${clone}" rev-parse --abbrev-ref HEAD)"
head="$(git -C "${clone}" rev-parse HEAD)"
if [ "${status}" -ne 0 ] && [ "${branch}" = "some-feature" ] && [ "${head}" = "${before}" ]; then
  pass "a checkout standing on a feature branch is left exactly where it was"
else
  fail "a checkout standing on a feature branch is left exactly where it was" \
    "status=${status} branch=${branch} out=${out}"
fi

# 2. And it SAYS so, naming the branch. A skipped move that leaves no trace is the whole defect: the
# incident was found only because an unrelated later step happened to fail.
assert_contains "and says which branch it refused to move off" "${out}" "some-feature"
assert_contains "and says nothing was installed, so the silence is not read as success" \
  "${out}" "Nothing was moved"

# 2a. A detached checkout is the other way to be somewhere that is not main, and it is refused too. The
# line says so in words: git prints the literal "HEAD" for that state, which reads as a branch of that
# name to anyone who does not work in git, and this window is read by somebody who does not.
clone="$(make_pair detached)"
git -C "${clone}" checkout --quiet --detach HEAD
ship_another "${clone}"
before="$(git -C "${clone}" rev-parse HEAD)"
out="$(overture_bring_checkout_current "${clone}" 2>&1)"
status=$?
head="$(git -C "${clone}" rev-parse HEAD)"
if [ "${status}" -ne 0 ] && [ "${head}" = "${before}" ]; then
  pass "a detached checkout is refused and left where it was"
else
  fail "a detached checkout is refused and left where it was" "status=${status} out=${out}"
fi
assert_contains "and the state is described rather than named as git names it" \
  "${out}" "a single commit with no branch"
assert_not_contains "so the bare word HEAD never reaches the person reading it" "${out}" 'on HEAD,'

# 3. Uncommitted work is refused, and nothing about the checkout moves.
clone="$(make_pair busy)"
git -C "${clone}" checkout --quiet -b in-flight
echo "half a change" >> "${clone}/file.txt"
ship_another "${clone}"
before="$(git -C "${clone}" rev-parse HEAD)"
out="$(overture_bring_checkout_current "${clone}" 2>&1)"
status=$?
after="$(git -C "${clone}" rev-parse HEAD)"
branch="$(git -C "${clone}" rev-parse --abbrev-ref HEAD)"
if [ "${status}" -ne 0 ] && [ "${before}" = "${after}" ] && [ "${branch}" = "in-flight" ]; then
  pass "a checkout with unsaved work is left exactly as it was"
else
  fail "a checkout with unsaved work is left exactly as it was" \
    "status=${status} branch=${branch} out=${out}"
fi
case "${out}" in
  *"unsaved work"*|*"in progress"*) pass "and says why, in words rather than git terms" ;;
  *) fail "and says why, in words rather than git terms" "got: ${out}" ;;
esac
if [ -n "$(git -C "${clone}" status --porcelain)" ]; then
  pass "and the unsaved work is still there"
else
  fail "and the unsaved work is still there"
fi

# 4. Already current is a clean no-op, which is the ordinary case every time Dan presses Update twice.
clone="$(make_pair current)"
out="$(overture_bring_checkout_current "${clone}" 2>&1)"
status=$?
head="$(git -C "${clone}" rev-parse HEAD)"
remote_head="$(git -C "${clone}" rev-parse origin/main)"
if [ "${status}" -eq 0 ] && [ "${head}" = "${remote_head}" ]; then
  pass "a checkout already on the shipped commit is left alone and reports success"
else
  fail "a checkout already on the shipped commit is left alone and reports success" \
    "status=${status} out=${out}"
fi

# 5. The move that survives #2923, and the reason the refusal above is not simply "never touch git":
# a checkout standing ON main, behind the remote, still fast-forwards. No branch changes hands, so
# nobody's session is redirected, and this is what the Update button is for.
clone="$(make_pair behind)"
ship_another "${clone}"
out="$(overture_bring_checkout_current "${clone}" 2>&1)"
status=$?
branch="$(git -C "${clone}" rev-parse --abbrev-ref HEAD)"
head="$(git -C "${clone}" rev-parse HEAD)"
remote_head="$(git -C "${clone}" rev-parse origin/main)"
if [ "${status}" -eq 0 ] && [ "${branch}" = "main" ] && [ "${head}" = "${remote_head}" ]; then
  pass "a checkout on main but behind is still brought up to the shipped commit"
else
  fail "a checkout on main but behind is still brought up to the shipped commit" \
    "status=${status} branch=${branch} out=${out}"
fi

if [ "${FAILURES}" -gt 0 ]; then
  echo "${FAILURES} check(s) failed"
  exit 1
fi
echo "all checks passed"
