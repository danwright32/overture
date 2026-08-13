#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501).
# shellcheck source=./shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shell-assertions.sh"

# Coverage for scripts/lib/test-all-phases.sh (#2603): the reporting decisions that come with running
# the cheap checks BESIDE the Swift suite instead of after it.
#
# The properties worth testing are the ones a real four minute suite run proves slowly and only for
# whichever lane happened to be red that day:
#   1. a cheap failure does not stop the cheap checks behind it
#   2. a cheap failure does not swallow the Swift verdict, and a Swift failure does not swallow the
#      cheap ones (L53: two independent checks must never share one status field)
#   3. when both lanes fail, BOTH are named
#   4. nothing written to the background log is lost, including lines written before streaming starts
#      and the last line if it has no trailing newline
#
# Every case drives fake phases (sh -c 'exit 1', a loop writing to a file), so the whole file runs in
# milliseconds and never invokes xcodebuild.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./test-all-phases.sh
source "${SCRIPT_DIR}/test-all-phases.sh"
set +e

FAILURES=0

# The recorded cheap failures as one string. Written through the `+` form because this Mac's bash is
# 3.2, where "${arr[@]}" on an EMPTY array is a fatal unbound-variable error under `set -u`, and half
# these cases assert that nothing was recorded.
cheap_failures() {
  printf '%s' "${TEST_ALL_CHEAP_FAILURES[@]+${TEST_ALL_CHEAP_FAILURES[*]}}"
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-all-phases-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

# --- run_foreground_check: records failures, never exits, keeps going ---

TEST_ALL_CHEAP_FAILURES=()
run_foreground_check "green one" true >/dev/null
run_foreground_check "red one" false >/dev/null
run_foreground_check "green two" true >/dev/null
RAN_AFTER_FAILURE="ran"
assert_eq "a failing cheap check does not stop the ones behind it" "ran" "${RAN_AFTER_FAILURE}"
assert_eq "exactly the failing check is recorded" "red one" "$(cheap_failures)"

TEST_ALL_CHEAP_FAILURES=()
run_foreground_check "red one" false >/dev/null
run_foreground_check "red two" sh -c 'exit 3' >/dev/null
assert_eq "every failing check is recorded, not just the first" \
  "red one red two" "$(cheap_failures)"

TEST_ALL_CHEAP_FAILURES=()
IMMEDIATE="$(run_foreground_check "typecheck" false 2>&1)"
assert_contains "a cheap failure is announced when it happens, not only in the summary" \
  "${IMMEDIATE}" "FAILED - typecheck"
assert_contains "and says the Swift suite is still running, so the wait is not mistaken for a hang" \
  "${IMMEDIATE}" "still running"

# A check whose command carries arguments must run with them, rather than the label being taken as one.
TEST_ALL_CHEAP_FAILURES=()
ARG_OUT="$(run_foreground_check "echoing check" echo "hello there" 2>&1)"
assert_contains "the command runs with its own arguments" "${ARG_OUT}" "hello there"
assert_empty "a passing check records nothing" "$(cheap_failures)"

# --- report_phase_results: both lanes always accounted for ---

TEST_ALL_CHEAP_FAILURES=()
OUT="$(report_phase_results "the Swift suite" 0 2>&1)"
assert_eq "both lanes green is a pass" "0" "$?"
assert_contains "both lanes green says so in one line" "${OUT}" "all suites passed"

TEST_ALL_CHEAP_FAILURES=("pnpm typecheck")
OUT="$(report_phase_results "the Swift suite" 0 2>&1)"
STATUS=$?
assert_eq "a cheap failure beside a green Swift run is still a red overall" "1" "${STATUS}"
assert_contains "the failing cheap check is named" "${OUT}" "pnpm typecheck"
# The half that a shared status field would lose: the Swift lane's own verdict.
assert_contains "the Swift verdict is reported even though a cheap check failed" \
  "${OUT}" "the Swift suite passed"

TEST_ALL_CHEAP_FAILURES=()
OUT="$(report_phase_results "the Swift suite" 65 2>&1)"
STATUS=$?
assert_eq "a failing Swift run with every cheap check green is red overall" "1" "${STATUS}"
assert_contains "the Swift failure names its exit status" "${OUT}" "exit 65"
# The mirror image: a green cheap lane must not read as though nothing else ran.
assert_contains "the cheap lane's clean result is stated too" "${OUT}" "every cheap check passed"

TEST_ALL_CHEAP_FAILURES=("pnpm test" "scripts/run-shell-fixtures.sh")
OUT="$(report_phase_results "the Swift suite" 1 2>&1)"
STATUS=$?
assert_eq "both lanes red is red" "1" "${STATUS}"
assert_contains "both cheap failures are named when the Swift suite failed too" "${OUT}" "pnpm test"
assert_contains "the second cheap failure is named as well" "${OUT}" "run-shell-fixtures.sh"
assert_contains "and the Swift failure is named beside them" "${OUT}" "the Swift suite failed"

# --- start_background_phase and stream_and_wait: nothing written is lost ---

LOG="${TMP_DIR}/phase.log"
start_background_phase "${LOG}" sh -c 'echo first; echo second; exit 0'
PID="${BACKGROUND_PHASE_PID}"
# Deliberately give the phase time to finish and to write BEFORE streaming starts, which is the real
# shape: the cheap lane takes about a minute, and the Swift suite has been writing the whole time.
sleep 0.5
STREAMED="$(stream_and_wait "${LOG}" "${PID}")"
STREAM_STATUS=$?
assert_contains "a line written before streaming started is still printed" "${STREAMED}" "first"
assert_contains "and so is the last one" "${STREAMED}" "second"
assert_eq "a clean background phase reports 0" "0" "${STREAM_STATUS}"

# The one that matters most: the FINAL lines, which is where TEST SUCCEEDED, the failing test names and
# the Suite shape line live. Written slowly, so the streamer reaches EOF while the writer is still alive
# and has to come back for more.
LOG2="${TMP_DIR}/phase2.log"
start_background_phase "${LOG2}" sh -c 'echo early; sleep 1; echo late; printf "** TEST SUCCEEDED **\n"; exit 0'
PID2="${BACKGROUND_PHASE_PID}"
STREAMED2="$(stream_and_wait "${LOG2}" "${PID2}")"
assert_contains "a line written after streaming started is printed" "${STREAMED2}" "late"
assert_contains "the final line is never lost to a race with the streamer" "${STREAMED2}" "TEST SUCCEEDED"

# A failing background phase's status reaches the caller, since the whole combined verdict hangs off it.
LOG3="${TMP_DIR}/phase3.log"
start_background_phase "${LOG3}" sh -c 'echo failing; exit 65'
PID3="${BACKGROUND_PHASE_PID}"
STREAMED3="$(stream_and_wait "${LOG3}" "${PID3}")"
assert_eq "a failing background phase's exit status is returned, not swallowed" "65" "$?"
assert_contains "its output is still streamed" "${STREAMED3}" "failing"

# A last line with NO trailing newline (a crash mid-write, or a tool that does not end with one) must
# still be printed rather than silently dropped.
LOG4="${TMP_DIR}/phase4.log"
start_background_phase "${LOG4}" sh -c 'printf "no trailing newline"; exit 0'
PID4="${BACKGROUND_PHASE_PID}"
STREAMED4="$(stream_and_wait "${LOG4}" "${PID4}")"
assert_contains "a final line with no trailing newline is still printed" "${STREAMED4}" "no trailing newline"

# A phase KILLED before it could record an outcome must not read as a pass. This is the case that made
# the status come from a file rather than from `wait`: `wait` answers only for a child of the shell
# asking, and its refusal (255) is indistinguishable from the phase itself having failed, while a status
# nobody wrote must be reported as exactly that.
LOG5="${TMP_DIR}/phase5.log"
start_background_phase "${LOG5}" sh -c 'echo working; sleep 30'
PID5="${BACKGROUND_PHASE_PID}"
STATUS_FILE5="${BACKGROUND_PHASE_STATUS_FILE}"
sleep 0.3
kill -9 "${PID5}" 2>/dev/null
KILLED_OUT="$(stream_and_wait "${LOG5}" "${PID5}" "${STATUS_FILE5}")"
KILLED_STATUS=$?
if [[ "${KILLED_STATUS}" -ne 0 ]]; then
  pass "a phase killed before it recorded an outcome is not a pass"
else
  fail "a phase killed before it recorded an outcome must not report success"
fi
assert_contains "and says that is why, rather than looking like an ordinary failure" \
  "${KILLED_OUT}" "never recorded how it ended"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "test-all-phases.test.sh: all assertions passed"
  exit 0
else
  echo "test-all-phases.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
