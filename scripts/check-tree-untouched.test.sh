#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/shell-assertions.sh"

# Coverage for check-tree-untouched.sh (#2318): a test run must leave the working tree exactly as it
# found it, and a run that writes into tracked files has to SAY SO rather than leaving edits that
# look exactly like a person's own work.
#
# Every case here builds a throwaway git repo in a temp directory, so nothing touches this checkout.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${SCRIPT_DIR}/check-tree-untouched.sh"

FAILURES=0

assert_equals() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected to contain: ${needle}"
    echo "  actual:              ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

make_repo() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/tree-untouched-fixture.XXXXXX")"
  git -C "${dir}" init -q
  git -C "${dir}" config user.email "fixture@localhost"
  git -C "${dir}" config user.name "Fixture"
  echo "original" > "${dir}/tracked.txt"
  git -C "${dir}" add tracked.txt
  git -C "${dir}" commit -q -m "initial"
  echo "${dir}"
}

# --- a run that changes nothing passes ---
REPO="$(make_repo)"
SNAPSHOT="${REPO}/.snapshot"
"${CHECK}" record "${REPO}" "${SNAPSHOT}" >/dev/null 2>&1
OUTPUT="$("${CHECK}" compare "${REPO}" "${SNAPSHOT}" 2>&1)"
assert_equals "an untouched tree passes" "0" "$?"
rm -rf "${REPO}"

# --- a run that rewrites a tracked file fails, and names the file ---
REPO="$(make_repo)"
SNAPSHOT="${REPO}/.snapshot"
"${CHECK}" record "${REPO}" "${SNAPSHOT}" >/dev/null 2>&1
echo "rewritten by the run" > "${REPO}/tracked.txt"
OUTPUT="$("${CHECK}" compare "${REPO}" "${SNAPSHOT}" 2>&1)"
EXIT=$?
assert_equals "a rewritten tracked file fails the run" "1" "${EXIT}"
assert_contains "the failure names the file that changed" "tracked.txt" "${OUTPUT}"
rm -rf "${REPO}"

# --- a run that creates a new untracked file fails too ---
# An added file is as indistinguishable from a person's own work as a modified one, and #1994's
# incident was exactly a generated file being mistaken for an edit somebody meant.
REPO="$(make_repo)"
SNAPSHOT="${REPO}/.snapshot"
"${CHECK}" record "${REPO}" "${SNAPSHOT}" >/dev/null 2>&1
echo "left behind" > "${REPO}/new-file.txt"
OUTPUT="$("${CHECK}" compare "${REPO}" "${SNAPSHOT}" 2>&1)"
EXIT=$?
assert_equals "a file left behind by the run fails" "1" "${EXIT}"
assert_contains "the failure names the file left behind" "new-file.txt" "${OUTPUT}"
rm -rf "${REPO}"

# --- a tree that was ALREADY dirty is still measured, and a further change to the same file fails ---
# The point of comparing content rather than asserting the tree is clean: nobody runs the suite on a
# pristine checkout, so a check that only means something on one would mean nothing on every real run.
REPO="$(make_repo)"
SNAPSHOT="${REPO}/.snapshot"
echo "my own work in progress" > "${REPO}/tracked.txt"
"${CHECK}" record "${REPO}" "${SNAPSHOT}" >/dev/null 2>&1
echo "the run overwrote my work" > "${REPO}/tracked.txt"
OUTPUT="$("${CHECK}" compare "${REPO}" "${SNAPSHOT}" 2>&1)"
EXIT=$?
assert_equals "a further change on an already dirty tree still fails" "1" "${EXIT}"
assert_contains "the failure names the file on a dirty tree" "tracked.txt" "${OUTPUT}"
rm -rf "${REPO}"

# --- work in progress present before the run is not blamed on the run ---
REPO="$(make_repo)"
SNAPSHOT="${REPO}/.snapshot"
echo "my own work in progress" > "${REPO}/tracked.txt"
echo "my own new file" > "${REPO}/scratch.txt"
"${CHECK}" record "${REPO}" "${SNAPSHOT}" >/dev/null 2>&1
"${CHECK}" compare "${REPO}" "${SNAPSHOT}" >/dev/null 2>&1
assert_equals "pre-existing uncommitted work passes" "0" "$?"
rm -rf "${REPO}"

# --- #2843: it says what it MEASURED, and never who did it ---
#
# The message used to assert "these edits were made by the suite, not by you" for every difference.
# It knows the tree changed; it does not know who changed it. On 2026-08-16 somebody committed their
# own work in another checkout sharing this repository mid-run, twenty modified paths went clean, and
# that sentence sent an agent 26 minutes into a suite defect that did not exist.
#
# Three buckets, and each is asserted to carry ONLY its own wording, because folding any two of them
# back together is the whole defect.

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected NOT to contain: ${needle}"
    echo "  actual:                  ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

# clean -> changed: the one case the suite writing looks like, and the only one the opt-in advice is
# true of.
REPO="$(make_repo)"
SNAPSHOT="${REPO}/.snapshot"
"${CHECK}" record "${REPO}" "${SNAPSHOT}" >/dev/null 2>&1
echo "rewritten by the run" > "${REPO}/tracked.txt"
OUTPUT="$("${CHECK}" compare "${REPO}" "${SNAPSHOT}" 2>&1)"
assert_contains "a file that went from clean to changed is named as exactly that" \
  "WENT FROM CLEAN TO CHANGED" "${OUTPUT}"
assert_contains "and it carries the opt-in advice" "opt-in" "${OUTPUT}"
assert_not_contains "and it no longer asserts who made the edit" "not by you" "${OUTPUT}"
rm -rf "${REPO}"

# changed -> clean: what a commit, stash or checkout looks like, including one made in another
# worktree sharing this repository. Reported, because a run CAN produce it by restoring a file over
# uncommitted work, but never as the suite writing.
REPO="$(make_repo)"
SNAPSHOT="${REPO}/.snapshot"
echo "my own work in progress" > "${REPO}/tracked.txt"
"${CHECK}" record "${REPO}" "${SNAPSHOT}" >/dev/null 2>&1
git -C "${REPO}" checkout -q -- tracked.txt
OUTPUT="$("${CHECK}" compare "${REPO}" "${SNAPSHOT}" 2>&1)"
EXIT=$?
assert_equals "a path that went clean during the run still fails" "1" "${EXIT}"
assert_contains "it is named as having gone clean" "ARE CLEAN NOW" "${OUTPUT}"
assert_contains "and the first thing offered is the cause that is not the suite" \
  "ANOTHER worktree sharing this repository" "${OUTPUT}"
assert_not_contains "it is never called an edit the suite wrote" "WENT FROM CLEAN TO CHANGED" "${OUTPUT}"
assert_not_contains "and it never offers the opt-in remedy, which changes nothing here" \
  "opt-in" "${OUTPUT}"
rm -rf "${REPO}"

# changed -> changed: genuinely indistinguishable, so it says so rather than picking a reading.
REPO="$(make_repo)"
SNAPSHOT="${REPO}/.snapshot"
echo "my own work in progress" > "${REPO}/tracked.txt"
"${CHECK}" record "${REPO}" "${SNAPSHOT}" >/dev/null 2>&1
echo "different again" > "${REPO}/tracked.txt"
OUTPUT="$("${CHECK}" compare "${REPO}" "${SNAPSHOT}" 2>&1)"
assert_contains "a path modified before and after says it cannot be told apart" \
  "cannot tell whether the run wrote these or you did" "${OUTPUT}"
assert_not_contains "and is not reported as the suite writing" "WENT FROM CLEAN TO CHANGED" "${OUTPUT}"
rm -rf "${REPO}"

# A path whose name holds a space is reported as one path, not two. It is the untracked scratch file
# a run is most likely to leave behind, and the buckets are decided by reading the path back out of
# each snapshot line.
REPO="$(make_repo)"
SNAPSHOT="${REPO}/.snapshot"
"${CHECK}" record "${REPO}" "${SNAPSHOT}" >/dev/null 2>&1
echo "left behind" > "${REPO}/a file with spaces.txt"
OUTPUT="$("${CHECK}" compare "${REPO}" "${SNAPSHOT}" 2>&1)"
assert_contains "a path with spaces is named whole" "a file with spaces.txt" "${OUTPUT}"
rm -rf "${REPO}"

# --- #3161: an ignored path the run wrote is SEEN, where before it was invisible ---
#
# `git status --porcelain -uall` lists tracked and untracked paths and NOT ignored ones, so a run
# that wrote a gitignored file into the repository was invisible to the guard whose whole job is
# noticing that a run changed the tree. Measured 2026-08-23 while building #2991: a fixture drove the
# real run-tests-locked.sh and its measuring case wrote `.overture-live-corpus-seen` into the
# repository root recording that both live-store invariants had examined rows on a day the live store
# held none of either. The guard passed clean; a person found it by reading the file afterwards.
#
# It REPORTS rather than fails, and each case below pins that, because the very file the incident was
# measured on is also written by an ordinary run whenever the invariants really do measure something.
# A check that fires on the ordinary case is a check somebody switches off (L93).

ignore_repo() {
  local dir
  dir="$(make_repo)"
  printf 'state-file\nbuild-dir/\n' > "${dir}/.gitignore"
  git -C "${dir}" add .gitignore
  git -C "${dir}" commit -q -m "ignore the state file and the build directory"
  echo "${dir}"
}

REPO="$(ignore_repo)"
SNAPSHOT="${REPO}/.snapshot"
"${CHECK}" record "${REPO}" "${SNAPSHOT}" >/dev/null 2>&1
echo "written by the run" > "${REPO}/state-file"
OUTPUT="$("${CHECK}" compare "${REPO}" "${SNAPSHOT}" 2>&1)"
EXIT=$?
assert_equals "an ignored file the run wrote does not fail the run" "0" "${EXIT}"
assert_contains "but the ignored file the run wrote is named" "state-file" "${OUTPUT}"
assert_contains "under a heading that says it is a report" \
  "IGNORED PATHS THIS RUN CHANGED" "${OUTPUT}"
assert_contains "and says which way it changed" "appeared:" "${OUTPUT}"
assert_not_contains "it is never reported as the suite writing a tracked file" \
  "WENT FROM CLEAN TO CHANGED" "${OUTPUT}"
assert_not_contains "and it never offers the opt-in remedy, which changes nothing here" \
  "opt-in" "${OUTPUT}"
rm -rf "${REPO}"

# An ignored path that was there before and is untouched says NOTHING. A report that speaks on every
# run is a report nobody reads (L36), and every real checkout here carries ignored paths already.
REPO="$(ignore_repo)"
SNAPSHOT="${REPO}/.snapshot"
echo "was here before the run" > "${REPO}/state-file"
"${CHECK}" record "${REPO}" "${SNAPSHOT}" >/dev/null 2>&1
OUTPUT="$("${CHECK}" compare "${REPO}" "${SNAPSHOT}" 2>&1)"
EXIT=$?
assert_equals "an unchanged ignored file passes" "0" "${EXIT}"
assert_equals "and the run says nothing at all about it" "" "${OUTPUT}"
rm -rf "${REPO}"

# CONTENT, not presence: the #2991 file already exists on a machine that has run the suite before, so
# a rule that only noticed a path APPEARING would have missed the incident on every later run.
REPO="$(ignore_repo)"
SNAPSHOT="${REPO}/.snapshot"
echo "was here before the run" > "${REPO}/state-file"
"${CHECK}" record "${REPO}" "${SNAPSHOT}" >/dev/null 2>&1
echo "the run rewrote it" > "${REPO}/state-file"
OUTPUT="$("${CHECK}" compare "${REPO}" "${SNAPSHOT}" 2>&1)"
EXIT=$?
assert_equals "rewriting an ignored file is still not a failure" "0" "${EXIT}"
assert_contains "but the rewritten ignored file is named" "state-file" "${OUTPUT}"
assert_contains "and says it was rewritten rather than newly written" "rewritten:" "${OUTPUT}"
rm -rf "${REPO}"

# An ignored path that went away is its own third thing, for the same reason the tracked side keeps
# clean -> changed apart from changed -> clean: they have different causes.
REPO="$(ignore_repo)"
SNAPSHOT="${REPO}/.snapshot"
echo "was here before the run" > "${REPO}/state-file"
"${CHECK}" record "${REPO}" "${SNAPSHOT}" >/dev/null 2>&1
rm -f "${REPO}/state-file"
OUTPUT="$("${CHECK}" compare "${REPO}" "${SNAPSHOT}" 2>&1)"
assert_contains "an ignored file the run deleted is named" "state-file" "${OUTPUT}"
assert_contains "and says it is gone rather than written" "gone:" "${OUTPUT}"
rm -rf "${REPO}"

# The verdict still comes from the TRACKED side alone. A run that touched both is a failure, and both
# lists are printed, so the report can never soften a real failure or invent one.
REPO="$(ignore_repo)"
SNAPSHOT="${REPO}/.snapshot"
"${CHECK}" record "${REPO}" "${SNAPSHOT}" >/dev/null 2>&1
echo "rewritten by the run" > "${REPO}/tracked.txt"
echo "written by the run" > "${REPO}/state-file"
OUTPUT="$("${CHECK}" compare "${REPO}" "${SNAPSHOT}" 2>&1)"
EXIT=$?
assert_equals "a tracked change alongside an ignored one still fails" "1" "${EXIT}"
assert_contains "the tracked file is still named" "tracked.txt" "${OUTPUT}"
assert_contains "and the ignored one is named beside it" "state-file" "${OUTPUT}"
rm -rf "${REPO}"

# Churn INSIDE an ignored directory is deliberately invisible: git collapses an ignored directory to
# a single entry, which is what keeps this cheap. Without that, `mac/build/` alone would put the whole
# of Xcode's output through a hash on every run, and the report would name thousands of paths that
# every run is supposed to write. Measured on this repository 2026-08-24: 12 entries this way against
# 9,690 with directories expanded.
REPO="$(ignore_repo)"
SNAPSHOT="${REPO}/.snapshot"
mkdir -p "${REPO}/build-dir"
echo "before" > "${REPO}/build-dir/one.txt"
"${CHECK}" record "${REPO}" "${SNAPSHOT}" >/dev/null 2>&1
echo "written during the run" > "${REPO}/build-dir/two.txt"
OUTPUT="$("${CHECK}" compare "${REPO}" "${SNAPSHOT}" 2>&1)"
EXIT=$?
assert_equals "churn inside an ignored directory passes" "0" "${EXIT}"
assert_equals "and is not reported, because the directory is one entry" "" "${OUTPUT}"
rm -rf "${REPO}"

# --- a missing snapshot is an error, never a pass ---
# The compare step runs at the end of a long suite, which is exactly where a silently skipped check
# would never be noticed. A snapshot that was never recorded means this measured nothing.
REPO="$(make_repo)"
OUTPUT="$("${CHECK}" compare "${REPO}" "${REPO}/never-recorded" 2>&1)"
EXIT=$?
assert_equals "a missing snapshot fails instead of passing" "1" "${EXIT}"
assert_contains "a missing snapshot says what it could not do" "snapshot" "${OUTPUT}"
rm -rf "${REPO}"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All check-tree-untouched.sh fixtures passed."
  exit 0
else
  echo "${FAILURES} check-tree-untouched.sh fixture(s) failed."
  exit 1
fi
