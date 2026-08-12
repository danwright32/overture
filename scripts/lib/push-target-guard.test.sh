#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/shell-assertions.sh"

# #2291: on 2026-08-07 a whole issue's work landed directly on main, past the pull request flow this repo
# uses for everything. Both existing pre-push gates passed, because neither asks which branch the push is
# going to, and the only visible sign was "HEAD -> main" in the push output.
#
# Every other control here assumes work arrives by PR: the pbxproj freshness check in the merge scripts,
# the CI gate, review itself. The one path that bypasses all of them was the only one with no guard.
#
# Drives the pure decision function against the exact stdin git hands a pre-push hook, and then drives the
# real hook end to end, because a decision function nothing calls guards nothing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HOOK="${REPO_ROOT}/scripts/hooks/pre-push"
ZERO="0000000000000000000000000000000000000000"
FAILURES=0

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected to contain: ${needle}"
    echo "  in: ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_empty() {
  local desc="$1" actual="$2"
  if [[ -z "${actual}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected nothing, got: ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

# shellcheck source=./push-target-guard.sh
source "${SCRIPT_DIR}/push-target-guard.sh"

# The ordinary case, and the one that must never be blocked: a branch on its way to a pull request.
assert_empty "pushing a feature branch is not a violation" \
  "$(printf 'refs/heads/2291-guard %s refs/heads/2291-guard %s\n' "abc123" "def456" \
    | protected_push_violations main)"

# The push that actually happened on 2026-08-07.
violations="$(printf 'refs/heads/main %s refs/heads/main %s\n' "abc123" "def456" \
  | protected_push_violations main)"
assert_contains "pushing main is a violation" "${violations}" "refs/heads/main"

# The same thing spelled the other way, which is how it happens by accident from a branch.
violations="$(printf 'HEAD %s refs/heads/main %s\n' "abc123" "def456" \
  | protected_push_violations main)"
assert_contains "pushing HEAD to main is a violation" "${violations}" "refs/heads/main"

# What the REMOTE ref says is what decides it. A local branch that happens to be called main going to some
# other remote branch is a normal push; a differently named local branch going to main is not.
assert_empty "a local branch named main pushed elsewhere is not a violation" \
  "$(printf 'refs/heads/main %s refs/heads/spike %s\n' "abc123" "def456" | protected_push_violations main)"

# Deleting the branch is at least as destructive as writing to it, and git signals it with an all-zero
# local sha rather than a different ref, so a guard keyed on the ref alone would wave it through.
violations="$(printf 'refs/heads/main %s refs/heads/main %s\n' "${ZERO}" "def456" \
  | protected_push_violations main)"
assert_contains "deleting main is a violation" "${violations}" "refs/heads/main"
assert_contains "and is named as a deletion, not as an ordinary push" "${violations}" "DELETING"

# git hands the hook every ref in one push. One bad ref among several must still be caught, and only the
# bad one named.
violations="$(printf 'refs/heads/a %s refs/heads/a %s\nrefs/heads/b %s refs/heads/main %s\n' \
  "1" "2" "3" "4" | protected_push_violations main)"
assert_contains "a protected ref hidden among several is still caught" "${violations}" "refs/heads/main"
if [[ "${violations}" == *"refs/heads/a"* ]]; then
  echo "FAIL - an innocent ref in the same push must not be named as a violation"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - and the innocent refs beside it are not named"
fi

# `git push` with nothing to do hands the hook no lines at all. That is not a violation, and a guard that
# treated an empty read as a match would block every no-op push.
assert_empty "a push with no refs at all is not a violation" "$(printf '' | protected_push_violations main)"

# --- the hook itself, end to end ---------------------------------------------------------------------
#
# The function above could be perfect and guard nothing if the hook did not call it, so this drives the
# real file the way git does: refs on stdin, remote name and URL as arguments.

if [[ -x "${HOOK}" ]]; then
  echo "ok - the pre-push hook exists and is executable"
else
  echo "FAIL - scripts/hooks/pre-push is missing or not executable, so git would never run it"
  FAILURES=$((FAILURES + 1))
fi

hook_output="$(printf 'refs/heads/main %s refs/heads/main %s\n' "abc123" "def456" \
  | "${HOOK}" origin https://github.com/danwright32/overture.git 2>&1)"
hook_status=$?
if [[ ${hook_status} -ne 0 ]]; then
  echo "ok - the hook refuses a push to main"
else
  echo "FAIL - the hook allowed a push straight to main"
  FAILURES=$((FAILURES + 1))
fi
assert_contains "and says which branch it refused" "${hook_output}" "main"
assert_contains "and names the way through" "${hook_output}" "ALLOW_PUSH_TO_MAIN"

hook_output="$(printf 'refs/heads/2291-guard %s refs/heads/2291-guard %s\n' "abc123" "def456" \
  | "${HOOK}" origin https://github.com/danwright32/overture.git 2>&1)"
if [[ $? -eq 0 ]]; then
  echo "ok - the hook lets an ordinary branch push through"
else
  echo "FAIL - the hook blocked an ordinary branch push"
  echo "  output: ${hook_output}"
  FAILURES=$((FAILURES + 1))
fi

# The override exists so a deliberate direct push is possible, and it is deliberately loud: the whole
# failure this guards against was invisible in the push output.
hook_output="$(printf 'refs/heads/main %s refs/heads/main %s\n' "abc123" "def456" \
  | ALLOW_PUSH_TO_MAIN=1 "${HOOK}" origin https://github.com/danwright32/overture.git 2>&1)"
if [[ $? -eq 0 ]]; then
  echo "ok - ALLOW_PUSH_TO_MAIN=1 lets a deliberate push to main through"
else
  echo "FAIL - the documented override did not work"
  FAILURES=$((FAILURES + 1))
fi
assert_contains "and the override still announces itself" "${hook_output}" "main"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all push-target-guard checks passed"
