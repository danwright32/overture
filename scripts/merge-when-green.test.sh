#!/usr/bin/env bash
set -uo pipefail

# Coverage for merge-when-green.sh's classify_stop_reason (#625): whether a check-pr-ci.sh
# output means "stop polling, and why" or "keep polling". Real-shaped fixtures of
# check-pr-ci.sh's actual output strings, not the live gh API, since this is a pure decision
# over already-produced text.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./merge-when-green.sh
source "${SCRIPT_DIR}/merge-when-green.sh"
set +e

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

# A PR with a merge conflict: check-pr-ci.sh's check_mergeable exits before it ever finds any
# check runs, so this is the ONLY line of output, unlike the other cases below.
CONFLICT_OUTPUT="PR #625 on danwright32/overture, commit abc1234

Unmergeable: PR #625 has a merge conflict against its base branch. GitHub never runs CI checks on a PR it can't merge, so waiting here would just time out. Resolve the conflict, then rerun."
assert_equals "a merge conflict is classified as conflict" "conflict" "$(classify_stop_reason "${CONFLICT_OUTPUT}")"

STALLED_OUTPUT="PR #1 on danwright32/overture, commit abc1234

typecheck-and-test: Passed
swift-tests: Stalled. Runner appears unreachable, status is offline (pending 6m40s).

Not every check has actually passed yet. Do not merge on the strength of pending or no failure yet alone."
assert_equals "a stalled runner is classified as stalled" "stalled" "$(classify_stop_reason "${STALLED_OUTPUT}")"

FAILED_OUTPUT="PR #1 on danwright32/overture, commit abc1234

typecheck-and-test: Failed
swift-tests: Passed

Not every check has actually passed yet. Do not merge on the strength of pending or no failure yet alone."
assert_equals "a genuine check failure is classified as failed" "failed" "$(classify_stop_reason "${FAILED_OUTPUT}")"

PENDING_OUTPUT="PR #1 on danwright32/overture, commit abc1234

typecheck-and-test: Pending
swift-tests: Still working (pending 19s)

Not every check has actually passed yet. Do not merge on the strength of pending or no failure yet alone."
assert_equals "still-pending checks are classified as keep-polling (empty)" "" "$(classify_stop_reason "${PENDING_OUTPUT}")"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All merge-when-green.sh classification fixtures passed."
  exit 0
else
  echo "${FAILURES} merge-when-green.sh classification fixture(s) failed."
  exit 1
fi
