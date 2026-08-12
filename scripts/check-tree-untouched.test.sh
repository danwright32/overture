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
