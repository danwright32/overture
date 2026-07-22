#!/usr/bin/env bash
set -uo pipefail

# Stubbed coverage for check-pr-ci.sh's classify_check_run and check_mergeable. #1347 retired
# the self-hosted swift-tests runner and #1352 removed the stall-detection this file used to
# cover; classify_check_run is now a pure text classifier over a completed/pending check with
# no gh calls of its own, so the fixtures drive it directly. check_mergeable's #625 conflict
# guard is unchanged and still guarded here.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Stub gh before sourcing so check-pr-ci.sh's top-level `command -v gh` guard (inside main,
# never run here) resolves to this instead of the network. classify_check_run and check_mergeable
# make no gh calls, so any gh call is unexpected and fails loudly.
gh() {
  echo "check-pr-ci.test.sh: unstubbed gh call: $*" >&2
  return 1
}

# shellcheck source=./check-pr-ci.sh
source "${SCRIPT_DIR}/check-pr-ci.sh"
# check-pr-ci.sh's own `set -euo pipefail` is now active in this shell too (source does
# not sandbox it). Turn errexit back off so one assertion's non-zero doesn't abort the
# rest of the run early.
set +e

FAILURES=0

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected to contain: ${needle}"
    echo "  actual: ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

# classify_check_run mutates EXIT_CODE in its CALLER, so an EXIT_CODE assertion has to invoke it
# directly, not inside a command substitution (a subshell would discard the mutation and every
# assertion would pass vacuously). assert_exit_code checks the caller's EXIT_CODE after such a call.
assert_exit_code() {
  local desc="$1" expected="$2"
  if [[ "${EXIT_CODE}" -eq "${expected}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc} (EXIT_CODE=${EXIT_CODE}, expected ${expected})"
    FAILURES=$((FAILURES + 1))
  fi
}

# --- a passed check reads as Passed and does not block ---
EXIT_CODE=0
out="$(classify_check_run "typecheck-and-test" "completed" "success")"
assert_contains "a passed check is reported as Passed" "${out}" "typecheck-and-test: Passed"
classify_check_run "typecheck-and-test" "completed" "success" >/dev/null
assert_exit_code "a passed check does not block the merge" 0

# --- a failed check reads as Failed and blocks ---
EXIT_CODE=0
out="$(classify_check_run "typecheck-and-test" "completed" "failure")"
assert_contains "a failed check is reported as Failed" "${out}" "typecheck-and-test: Failed"
classify_check_run "typecheck-and-test" "completed" "failure" >/dev/null
assert_exit_code "a failed check blocks the merge" 1

# --- a pending check reads as Pending and blocks. With the self-hosted runner gone there is
# no "stalled" distinction: the only check runs on GitHub-hosted ubuntu-latest, so a bare
# Pending (which blocks) is the honest report and can never be silently swallowed. ---
EXIT_CODE=0
out="$(classify_check_run "typecheck-and-test" "in_progress" "")"
assert_contains "a pending check is reported as Pending" "${out}" "typecheck-and-test: Pending"
classify_check_run "typecheck-and-test" "in_progress" "" >/dev/null
assert_exit_code "a pending check blocks the merge" 1

# It must NEVER read as Passed: the whole point of this script is that Dan can tell a check that
# actually ran and went green apart from one still pending (the repo's "a pending check and a
# stuck one look identical" rule).
if [[ "${out}" == *"Passed"* ]]; then
  echo "FAIL - a pending check must not be reported as Passed: ${out}"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - a pending check is not reported as Passed"
fi

# --- a skipped check is unexpected (typecheck-and-test has no path filter, so nothing should
# skip it) and blocks. It must never read as Passed. ---
EXIT_CODE=0
out="$(classify_check_run "typecheck-and-test" "completed" "skipped")"
assert_contains "a skipped check is reported as Skipped" "${out}" "Skipped"
classify_check_run "typecheck-and-test" "completed" "skipped" >/dev/null
assert_exit_code "an unexpectedly skipped check blocks the merge" 1

# --- check_mergeable (#625): a PR with a real merge conflict never gets CI checks at all, so
# polling check-runs for one just times out reporting "No checks found yet" for the full
# MAX_WAIT_SECONDS. check_mergeable lets main() fail fast on that specific case instead. ---
PR_NUMBER="999"

if check_mergeable "CONFLICTING" >/tmp/check-pr-ci-mergeable-out.$$ 2>&1; then
  echo "FAIL - check_mergeable(\"CONFLICTING\") should return non-zero"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - check_mergeable(\"CONFLICTING\") returns non-zero"
fi
assert_contains "check_mergeable(\"CONFLICTING\") names the PR and explains why polling won't help" \
  "$(cat /tmp/check-pr-ci-mergeable-out.$$)" "PR #999 has a merge conflict"
rm -f /tmp/check-pr-ci-mergeable-out.$$

if check_mergeable "MERGEABLE" >/dev/null 2>&1; then
  echo "ok - check_mergeable(\"MERGEABLE\") returns success"
else
  echo "FAIL - check_mergeable(\"MERGEABLE\") should return success"
  FAILURES=$((FAILURES + 1))
fi

# UNKNOWN means GitHub hasn't finished computing mergeability yet (e.g. moments after a push),
# not a real conflict. Must not be treated as a hard failure, or every fresh push would false-stop.
if check_mergeable "UNKNOWN" >/dev/null 2>&1; then
  echo "ok - check_mergeable(\"UNKNOWN\") returns success (not yet computed is not a conflict)"
else
  echo "FAIL - check_mergeable(\"UNKNOWN\") should not be treated as a conflict"
  FAILURES=$((FAILURES + 1))
fi

echo
if [[ ${FAILURES} -eq 0 ]]; then
  echo "All check-pr-ci.sh classification fixtures passed."
  exit 0
else
  echo "${FAILURES} check-pr-ci.sh classification fixture(s) failed."
  exit 1
fi
