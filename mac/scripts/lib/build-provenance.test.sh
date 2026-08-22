#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary (#2501).
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../scripts" && pwd)/lib/shell-assertions.sh"

# #2553: where the installed build came from, decided at install time by the one thing that can run git.
#
# The freshness panel compared the installed bundle's commit DATE against the newest shipped commit's
# date, so a build made from an unmerged branch AFTER the latest commit on main reported "up to date" in
# exactly the words a correct install uses. Hit 2026-08-11: the app in /Applications had been replaced at
# 21:22 while several agents were running, and there was no way from the repo to tell whether it came
# from main or from somebody's branch. It turned out to be Dan pressing Update, confirmed by asking him,
# which is not a check.
#
# It matters because the live app holds the real store, so an unmerged build running against it is the
# one state nobody would notice: the panel actively says everything is current.
#
# Everything here runs against throwaway repositories with a LOCAL bare remote. Nothing reaches the
# network, and nothing reads Dan's checkout.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./build-provenance.sh
source "${HERE}/build-provenance.sh"

FAILURES=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# A repo with a bare `origin` holding main, and one commit on main.
make_repo() {
  # Assigned on separate lines: within one `local` statement the earlier names are not yet visible to
  # the later ones, and under `set -u` that is an unbound variable rather than an empty string.
  local name="$1"
  local repo="${WORK}/${name}"
  local origin="${WORK}/${name}-origin.git"
  git init --quiet --bare "${origin}"
  git init --quiet -b main "${repo}"
  git -C "${repo}" remote add origin "${origin}"
  echo one > "${repo}/file"
  git -C "${repo}" add -A && git -C "${repo}" commit --quiet -m one
  git -C "${repo}" push --quiet origin main
  echo "${repo}"
}

# --- HEAD on main, which is what a correct install looks like ---------------------------------------
ON_MAIN="$(make_repo on-main)"
assert_equals "a checkout standing on main reports main" "main" "$(build_provenance "${ON_MAIN}")"

# --- a commit that is not on main yet ---------------------------------------------------------------
# The whole case. An unmerged branch build is NEWER than everything on main, which is exactly why a
# comparison of dates called it current.
BRANCH="$(make_repo branch)"
git -C "${BRANCH}" checkout --quiet -b feature
echo two > "${BRANCH}/file"
git -C "${BRANCH}" commit --quiet -am two
assert_equals "a build from an unmerged branch reports branch" "branch" "$(build_provenance "${BRANCH}")"

# --- a branch NAME whose commit is already on main is not a branch build ------------------------------
# Judged on ancestry, never on the branch name: work that has shipped is shipped whatever ref is checked
# out, and calling it a branch build would put a warning in front of Dan on every ordinary install made
# from a checkout that happens not to be standing on main.
SHIPPED="$(make_repo shipped)"
git -C "${SHIPPED}" checkout --quiet -b already-merged
assert_equals "a branch pointing at a commit already on main reports main" "main" "$(build_provenance "${SHIPPED}")"

# --- a detached HEAD on a commit that is on main -------------------------------------------------------
DETACHED="$(make_repo detached)"
git -C "${DETACHED}" checkout --quiet --detach HEAD
assert_equals "a detached HEAD on a shipped commit reports main" "main" "$(build_provenance "${DETACHED}")"

# --- everything it CANNOT answer says so, and never accuses --------------------------------------------
# An accusation made from an index that is merely incomplete is worse than no answer: it would tell Dan
# his ordinary install came from an unmerged branch, and re-installing would not clear it (L119).
NO_REMOTE="${WORK}/no-remote"
git init --quiet -b main "${NO_REMOTE}"
echo one > "${NO_REMOTE}/file"
git -C "${NO_REMOTE}" add -A && git -C "${NO_REMOTE}" commit --quiet -m one
assert_equals "a checkout with no origin reports unknown, not branch" "unknown" "$(build_provenance "${NO_REMOTE}")"

# An unreachable remote, on a commit the LOCAL ref does not already vouch for. This is the case that
# must never be reported as `branch`, and it is written with an unmerged commit on purpose: with a
# commit already on the local origin/main there is nothing to reach for and the case would prove nothing.
GONE="$(make_repo gone)"
git -C "${GONE}" checkout --quiet -b feature
echo two > "${GONE}/file"
git -C "${GONE}" commit --quiet -am two
rm -rf "${WORK}/gone-origin.git"
assert_equals "a remote that cannot be reached reports unknown, not branch" "unknown" "$(build_provenance "${GONE}")"

# The refresh is only reached for when this is about to ACCUSE, so an ordinary install whose commit the
# local ref already vouches for needs no network at all. Proved by taking the remote away entirely: a
# rule that fetched first would answer `unknown` here, on the commonest case there is.
OFFLINE="$(make_repo offline)"
rm -rf "${WORK}/offline-origin.git"
assert_equals "a shipped commit is recognised with the remote gone, so the common case needs no network" \
  "main" "$(build_provenance "${OFFLINE}")"

# And a STALE local ref is not an accusation. The commit is on the remote's main and the local
# origin/main has been wound back behind it, which is exactly the state a checkout is in between somebody
# else's merge and its next fetch.
STALE="$(make_repo stale)"
echo two > "${STALE}/file"
git -C "${STALE}" commit --quiet -am two
git -C "${STALE}" push --quiet origin main
git -C "${STALE}" update-ref refs/remotes/origin/main "$(git -C "${STALE}" rev-parse HEAD~1)"
assert_equals "a commit the local ref has not caught up with is not called a branch build" \
  "main" "$(build_provenance "${STALE}")"

assert_equals "a path that is not a repository at all reports unknown" "unknown" "$(build_provenance "${WORK}/nowhere")"

# --- it must answer one of exactly three words ---------------------------------------------------------
# The Swift side decodes this string, and a fourth spelling would silently become its unknown branch.
for repo in "${ON_MAIN}" "${BRANCH}" "${NO_REMOTE}" "${WORK}/nowhere"; do
  answer="$(build_provenance "${repo}")"
  case "${answer}" in
    main|branch|unknown) pass "answered with a word the reader knows: ${answer}" ;;
    *) fail "build_provenance answered '${answer}', which nothing reads" ;;
  esac
done

# --- and the installer actually USES it -----------------------------------------------------------
#
# A rule that is correct and unwired is the same as no rule (L3), and every assertion above this line
# would pass just as well with `mac/build-install.sh` still writing a v1 record. Asserted through a grep
# that answers yes or no rather than by passing the whole script as a haystack, because a failing
# assert_contains prints its haystack and build-install.sh is long.
INSTALLER="${HERE}/../../build-install.sh"
installer_holds() { grep -q -- "$1" "${INSTALLER}" && echo found || echo missing; }

assert_equals "build-install.sh sources this rule" "found" "$(installer_holds 'lib/build-provenance.sh')"
assert_equals "and calls it" "found" "$(installer_holds 'build_provenance "${OVERTURE_REPO_ROOT}"')"
assert_equals "and writes the answer into the record" "found" "$(installer_holds '"provenance":"%s"')"
# The version has to move with the shape, or a reader cannot tell a record that predates the field from
# one whose installer could not answer.
assert_equals "and the record says it is version 2" "found" "$(installer_holds '"version":2')"
assert_equals "so nothing still writes the old shape" "missing" "$(installer_holds '"version":1')"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "build-provenance.test.sh: all assertions passed"
  exit 0
fi
echo "build-provenance.test.sh: ${FAILURES} assertion(s) failed"
exit 1
