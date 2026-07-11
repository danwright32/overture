#!/usr/bin/env bash
set -uo pipefail

# Stubbed coverage for check-pr-ci.sh's swift-tests pending/stalled classification
# (classify_check_run and its helpers). This is the exact code path that hid two real
# bugs (#506/#514): a nonexistent `gh api --arg` flag, and reading the check run's
# started_at instead of the job's created_at. "Run it against a real completed PR"
# structurally never exercises this path, so these fixtures stub `gh` (as a shell
# function, which bash resolves before PATH) to drive it directly.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Stub out gh before sourcing, so check-pr-ci.sh's own top-level `command -v gh` guard
# (inside main, harmless) and every runtime call resolve to this instead of the network.
gh() {
  local args="$*"
  if [[ "${args}" == "auth token"* ]]; then
    echo "stub-token"
    return 0
  fi
  if [[ "${args}" == *"/actions/runners"* ]]; then
    [[ "${STUB_RUNNER_PRESENT:-0}" == "1" ]] && printf '%s\t%s\n' "${STUB_RUNNER_STATUS}" "${STUB_RUNNER_BUSY}"
    return 0
  fi
  if [[ "${args}" == *"/actions/runs?head_sha="* ]]; then
    echo "${STUB_RUN_ID:-1}"
    return 0
  fi
  if [[ "${args}" == *"/actions/runs/"*"/jobs"* ]]; then
    echo "${STUB_JOB_CREATED_AT}"
    return 0
  fi
  echo "check-pr-ci.test.sh: unstubbed gh call: ${args}" >&2
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

# resolve_queue_created_at reads SHA as a global (main() normally sets it from a real PR
# lookup); the value is a fixture placeholder, since our gh() stub matches on path shape,
# not on the actual sha.
SHA="deadbeef"

# Fixed clock for the whole run so every scenario's elapsed-time math is exact and
# reproducible, instead of drifting with wall-clock time between scenarios.
NOW=$(date -u +%s)
seconds_ago_iso() {
  date -u -r $(( NOW - $1 )) +%Y-%m-%dT%H:%M:%SZ
}

# --- queued: job created moments ago, nowhere near the stall threshold ---
STUB_JOB_CREATED_AT="$(seconds_ago_iso 10)"
STUB_RUNNER_PRESENT=0
RUNNER_CHECKED=0; RUNNER_STATUS=""; RUNNER_BUSY=""
out="$(classify_check_run "swift-tests" "queued" "111" "")"
assert_contains "queued: reported as still working" "${out}" "Still working (pending 10s)"

# --- in-progress-fast: already picked up, still well under the threshold ---
STUB_JOB_CREATED_AT="$(seconds_ago_iso 45)"
STUB_RUNNER_PRESENT=0
RUNNER_CHECKED=0; RUNNER_STATUS=""; RUNNER_BUSY=""
out="$(classify_check_run "swift-tests" "in_progress" "222" "")"
assert_contains "in-progress-fast: reported as still working" "${out}" "Still working (pending 45s)"

# --- in-progress-past-threshold-with-runner-online: past 300s, runner online+busy ---
STUB_JOB_CREATED_AT="$(seconds_ago_iso 400)"
STUB_RUNNER_PRESENT=1
STUB_RUNNER_STATUS="online"
STUB_RUNNER_BUSY="true"
RUNNER_CHECKED=0; RUNNER_STATUS=""; RUNNER_BUSY=""
out="$(classify_check_run "swift-tests" "in_progress" "333" "")"
assert_contains "past-threshold + runner online: still working, longer than usual" "${out}" "Still working, longer than usual, but the runner is online and busy (pending 6m40s)"

# --- runner-offline: past 300s, runner registered but not online ---
STUB_JOB_CREATED_AT="$(seconds_ago_iso 400)"
STUB_RUNNER_PRESENT=1
STUB_RUNNER_STATUS="offline"
STUB_RUNNER_BUSY="false"
RUNNER_CHECKED=0; RUNNER_STATUS=""; RUNNER_BUSY=""
out="$(classify_check_run "swift-tests" "in_progress" "444" "")"
assert_contains "runner-offline: reported as stalled, unreachable" "${out}" "Stalled. Runner appears unreachable, status is offline (pending 6m40s)"

# --- skipped (#761): a PR that touches no Swift, fixtures or CI-script file does not run
# swift-tests at all, so the job reports conclusion "skipped". That is an INTENTIONAL skip
# (the path filter in ci.yml decided the Mac tests prove nothing about this change), not a
# failure, and it must not block the merge. Before this, `skipped` fell into the catch-all
# arm and was treated as not-passed, which is what left every Dependabot PR unmergeable.
#
# NOTE: classify_check_run mutates EXIT_CODE in its CALLER, so it has to be invoked directly
# here, not inside a command substitution. `out="$(classify_check_run ...)"` runs it in a
# subshell, where the mutation is discarded and every EXIT_CODE assertion would pass vacuously.
# The existing scenarios above only assert on printed text, so they never hit this.
assert_exit_code() {
  local desc="$1" expected="$2"
  if [[ "${EXIT_CODE}" -eq "${expected}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc} (EXIT_CODE=${EXIT_CODE}, expected ${expected})"
    FAILURES=$((FAILURES + 1))
  fi
}

EXIT_CODE=0
out="$(classify_check_run "swift-tests" "completed" "555" "skipped")"
assert_contains "skipped swift-tests: reported as skipped" "${out}" "Skipped"

# It must NEVER read as "Passed": the whole point of this script is that Dan can tell a check
# that actually ran and went green apart from one that never ran at all (the repo's own
# "a pending check and a stuck one look identical" rule).
if [[ "${out}" == *"Passed"* ]]; then
  echo "FAIL - a skipped check must not be reported as Passed: ${out}"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - a skipped swift-tests is not reported as Passed"
fi

EXIT_CODE=0
classify_check_run "swift-tests" "completed" "555" "skipped" >/dev/null
assert_exit_code "an intentionally skipped swift-tests does not block the merge" 0

# --- a skipped check that is NOT swift-tests is still not a pass. Only the Mac job has a
# legitimate path-filtered skip; anything else skipping is unexpected and must be surfaced.
EXIT_CODE=0
classify_check_run "typecheck-and-test" "completed" "666" "skipped" >/dev/null
assert_exit_code "an unexpectedly skipped check still blocks the merge" 1

EXIT_CODE=0

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
