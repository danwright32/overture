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
# --- base branch health (#1006 fallout) -------------------------------------------------
#
# check_pr_ci asks "did THIS branch pass". Nothing asked "is main green BEFORE I land on it",
# and on 2026-07-16 PR #1004 was merged onto a main that had been red for 29 minutes. Its own
# branch genuinely passed, so every existing gate reported truthfully and the merge still made a
# bad situation ambiguous: once a second change lands on a red main, nobody can tell which one
# broke it.
#
# A red base BLOCKS, but must be overridable, or the fix that makes main green could never be
# merged: the gate would deadlock exactly when it matters most.
#
# An UNKNOWN base does NOT block. It is not evidence of breakage, and GitHub's Actions API
# returned 503 for the whole of this session's investigation. A gate that stops all work during
# someone else's outage is a worse failure than the one it prevents. It warns instead, and the
# PR's own checks remain the real gate.

assert_equals "a green base is fine, no stop reason" \
  "" "$(base_branch_stop_reason "success")"

assert_equals "a red base blocks the merge" \
  "base-red" "$(base_branch_stop_reason "failure")"

# A cancelled or timed-out base is not a pass. It has NOT been seen to be green, which is the
# whole point: this repo's rule is that absence of failure is not a pass.
assert_equals "a cancelled base blocks the merge" \
  "base-red" "$(base_branch_stop_reason "cancelled")"
assert_equals "a timed-out base blocks the merge" \
  "base-red" "$(base_branch_stop_reason "timed_out")"

# The override exists so the FIX for a red main can land. Explicit, never a default.
assert_equals "an explicit override lets a merge land on a red base" \
  "" "$(base_branch_stop_reason "failure" "allow-red-base")"

# An API outage, an empty run list, or a base whose run is still going: unknown, not red.
assert_equals "an unknown base warns rather than blocks" \
  "base-unknown" "$(base_branch_stop_reason "")"
assert_equals "a base still running is unknown, not red" \
  "base-unknown" "$(base_branch_stop_reason "in_progress")"

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All merge-when-green.sh classification fixtures passed."
  exit 0
else
  echo "${FAILURES} merge-when-green.sh classification fixture(s) failed."
  exit 1
fi
