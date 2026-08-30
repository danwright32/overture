#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501).
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"

# #2577: a test run that STARTS fine and then stops progressing looks exactly like a slow one.
#
# Every file this touches is a throwaway under its own temporary directory. Nothing here reads this
# Mac's real runs, its lock, or its DerivedData (L2).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./test-progress-watch.sh
source "${SCRIPT_DIR}/test-progress-watch.sh"
set +e

FAILURES=0

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ---------------------------------------------------------------------------
# What counts as the run having MOVED
# ---------------------------------------------------------------------------
# Asserted through progress_count, which is the function the run actually calls, rather than through
# a per-line predicate written for the fixture's convenience. A bash `=~` twin of the same pattern
# would be judged by a different regex engine from the grep that ships, so it could agree with itself
# perfectly while the real thing behaved otherwise (L26, L52).
# Every line in this block was read off a REAL run on this Mac (L48): the xcresult bundle
# Test-Overture-2026.08.12_15-36-06--0400.xcresult under
# ~/Library/Developer/Xcode/DerivedData/Overture-cnqddrhfypsdzkbkmkqmrabddxqj/Logs/Test, extracted
# with `xcrun xcresulttool get log --type action`. Nothing here is invented, because a matcher
# calibrated on an imagined format matches an imagined run.
#
# The pass, fail and started marks Swift Testing prints are built from their UTF-8 bytes rather than
# typed, exactly as suite-stats.test.sh does (#2193): the pre-push style gate forbids those
# characters in source and cannot tell a line that USES one from a line that must QUOTE one.
PASS_MARK="$(printf '\xe2\x9c\x94')"
FAIL_MARK="$(printf '\xe2\x9c\x98')"
STARTED_MARK="$(printf '\xe2\x97\x87')"

# One line, written to a real file and counted by the real counter.
count_of_line() {
  printf '%s\n' "$1" > "${TMP_DIR}/one-line.log"
  progress_count "${TMP_DIR}/one-line.log"
}

assert_progress() {
  local desc="$1" line="$2" got
  got="$(count_of_line "${line}")"
  if [[ "${got}" == "1" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected this line to count as progress (got ${got}): ${line}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_not_progress() {
  local desc="$1" line="$2" got
  got="$(count_of_line "${line}")"
  if [[ "${got}" == "0" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected this line NOT to count as progress (got ${got}): ${line}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_progress "a Swift Testing test finishing" \
  "${PASS_MARK} Test everyProbeResultGetsItsOwnContactRoute() passed after 0.001 seconds."
assert_progress "a Swift Testing test FAILING is progress too, the run moved" \
  "${FAIL_MARK} Test somethingBroke() failed after 0.204 seconds."
assert_progress "a Swift Testing test starting" \
  "${STARTED_MARK} Test nilIsTheOnlyWayToTheUncheckedRoute() started."
assert_progress "a Swift Testing suite finishing" \
  "${PASS_MARK} Suite \"ProbeResult, ContactRoute and Badge stay in step (#2528)\" passed after 0.013 seconds."
assert_progress "the run's own opening line" "${STARTED_MARK} Test run started."
assert_progress "the whole run's closing total" \
  "${PASS_MARK} Test run with 5923 tests in 835 suites passed after 102.546 seconds."
assert_progress "the XCTest side's suite start" \
  "Test Suite 'OvertureTests.xctest' started at 2026-08-12 15:36:46.919."
assert_progress "the XCTest side's suite result" \
  "Test Suite 'Selected tests' passed at 2026-08-12 15:36:46.919."
assert_progress "an XCTest case result" \
  "Test Case '-[OvertureTests testExample]' passed (0.002 seconds)."

# The marks are decoration, so the matcher must not depend on them. A future Swift Testing that
# stopped printing them, or an xcodebuild that stripped them, would otherwise silently match nothing,
# and a progress counter that can never rise reports every healthy run as stalled (L36: the alarm
# that cries wolf gets ignored, and this one would cry on every run).
assert_progress "a completion line with no mark in front of it" \
  "Test someTest() passed after 0.001 seconds."

# The other half, and the whole point of the issue. The hang measured on 2026-08-12 wrote 21MB of
# repeated error output while nothing progressed, so anything derived from the log's SIZE would have
# gone on reporting a healthy run for the entire hour. These lines are constructed rather than
# recorded (the incident's log was not kept), and they are deliberately the noisiest shapes a run
# emits: what they assert is that a line has to REPORT a test to count, not merely mention one.
assert_not_progress "the library version banner" "${PASS_MARK} Testing Library Version: 1902"
assert_not_progress "a compile line" \
  "CompileSwift normal arm64 /Users/dan/Overture/mac/Overture/Prospect.swift"
assert_not_progress "the final banner is not a test finishing" "** TEST SUCCEEDED **"
assert_not_progress "the failed banner either" "** TEST FAILED **"
assert_not_progress "repeated CoreData noise, the shape that filled 21MB" \
  "CoreData: error: SQLCore dispatchRequest: exception handling request, no test involved"
assert_not_progress "a line that merely says the word test" \
  "note: Building targets in dependency order for the test action"
assert_not_progress "an empty line" ""

# ---------------------------------------------------------------------------
# watch_phase: WAITING for the shared lock is not the same fact as STALLING
# ---------------------------------------------------------------------------
# This is the distinction the whole guard turns on. xcodebuild is serialised behind one lock across
# every worktree on this Mac, so a run can legitimately sit for many minutes before it starts. flock
# writes nothing and execs xcodebuild only once it holds the lock, so a queued run's log is EMPTY:
# zero bytes is therefore proof of queueing rather than a guess at it.

assert_eq "an empty log means the run has not started, it is queued behind the lock" \
  "queued" "$(watch_phase 0 0)"
assert_eq "bytes but no test yet means it is building" \
  "building" "$(watch_phase 48213 0)"
assert_eq "once any test has reported, the run is testing" \
  "testing" "$(watch_phase 48213 1)"
assert_eq "a huge log with no test in it is still only building, size proves nothing" \
  "building" "$(watch_phase 21000000 0)"

# ---------------------------------------------------------------------------
# notice_due: one predicate behind every repeated message
# ---------------------------------------------------------------------------
# The stall warning and the still-waiting-for-the-lock notice repeat on their own cadences, and both
# ask the same question, so they ask it of one function rather than two that can drift (L16).

assert_due() {
  local desc="$1" elapsed="$2" every="$3" given="$4"
  if notice_due "${elapsed}" "${every}" "${given}"; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected a notice to be due at ${elapsed}s, every ${every}s, ${given} given"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_not_due() {
  local desc="$1" elapsed="$2" every="$3" given="$4"
  if notice_due "${elapsed}" "${every}" "${given}"; then
    echo "FAIL - ${desc}"
    echo "  expected NO notice at ${elapsed}s, every ${every}s, ${given} given"
    FAILURES=$((FAILURES + 1))
  else
    echo "ok - ${desc}"
  fi
}

assert_not_due "nothing is due before the first limit is reached" 599 600 0
assert_due "the first one is due the moment the limit is reached" 600 600 0
assert_not_due "and it is not due twice" 900 600 1
assert_due "the second is due one whole limit later, not on the next tick" 1200 600 1
assert_not_due "an unset cadence never fires, so a mistyped limit cannot warn on every run" 99999 "" 0
assert_not_due "nor does a non-numeric one" 99999 "ten" 0
assert_not_due "nor a zero one, which is how a caller switches this off" 99999 0 0

# ---------------------------------------------------------------------------
# The messages themselves
# ---------------------------------------------------------------------------
# The stall warning has one job beyond saying "no progress": it must rule OUT the lock, because
# "waiting on the suite" was exactly what three status reports said while the work was already dead,
# and the reason that reading was believable is that waiting really is the common case here.

STALL_TEXT="$(stall_warning 600 4213)"
assert_contains "the warning says how long nothing has finished for" "${STALL_TEXT}" "10m"
assert_contains "and how many tests did finish, so the reader knows the run really started" \
  "${STALL_TEXT}" "4213"
assert_contains "and rules out the lock by name, which is the reading it exists to correct" \
  "${STALL_TEXT}" "not waiting for the shared lock"

LOCK_TEXT="$(lock_wait_notice 900)"
assert_contains "the queued notice says how long it has waited" "${LOCK_TEXT}" "15m"
assert_contains "and says plainly that this is a queue, not a stall" "${LOCK_TEXT}" "not stalled"

assert_contains "the lock-acquired line reports what the wait actually cost" \
  "$(lock_acquired_notice 420)" "7m"

# A warning that turns out to be wrong has to be withdrawn in the same place it was made, or the
# reader is left with a stall warning over a run that finished perfectly well (L11).
assert_contains "a resumed run retracts the warning above it" \
  "$(progress_resumed_notice 660)" "false alarm"

# ---------------------------------------------------------------------------
# humanize_seconds
# ---------------------------------------------------------------------------
assert_eq "seconds under a minute" "45s" "$(humanize_seconds 45)"
assert_eq "a whole minute" "1m" "$(humanize_seconds 60)"
assert_eq "minutes round down, so the figure never overstates the wait" \
  "10m" "$(humanize_seconds 659)"
assert_eq "an hour and change" "1h 5m" "$(humanize_seconds 3900)"
assert_eq "exactly an hour" "1h 0m" "$(humanize_seconds 3600)"
assert_eq "zero" "0s" "$(humanize_seconds 0)"

# ---------------------------------------------------------------------------
# Counting a whole log, and the shapes that make a count stop being a number
# ---------------------------------------------------------------------------

EMPTY_LOG="${TMP_DIR}/empty.log"
: > "${EMPTY_LOG}"
assert_eq "an empty log has no progress in it" "0" "$(progress_count "${EMPTY_LOG}")"
assert_eq "and no bytes" "0" "$(log_bytes "${EMPTY_LOG}")"

# grep -c prints 0 AND exits nonzero when nothing matches, which is the shape that turns a
# `|| echo 0` fallback into the two-line answer "0\n0". Asserted because a count read as "0 0"
# poisons every arithmetic comparison downstream and bash says nothing about it.
NOISE_LOG="${TMP_DIR}/noise.log"
{
  echo "Command line invocation:"
  echo "CompileSwift normal arm64 /Users/dan/Overture/mac/Overture/Prospect.swift"
  echo "CoreData: error: SQLCore dispatchRequest: exception handling request"
} > "${NOISE_LOG}"
assert_eq "a log full of noise counts exactly zero, on one line" \
  "0" "$(progress_count "${NOISE_LOG}")"
assert_eq "and it is a building run, not a queued one" \
  "building" "$(watch_phase "$(log_bytes "${NOISE_LOG}")" "$(progress_count "${NOISE_LOG}")")"

RUNNING_LOG="${TMP_DIR}/running.log"
{
  echo "Command line invocation:"
  echo "${STARTED_MARK} Test run started."
  echo "${PASS_MARK} Test alpha() passed after 0.001 seconds."
  echo "${PASS_MARK} Test beta() passed after 0.002 seconds."
  echo "CoreData: error: noise between two real tests"
} > "${RUNNING_LOG}"
assert_eq "three progress lines, and the noise between them counts for nothing" \
  "3" "$(progress_count "${RUNNING_LOG}")"

# A log that is not there at all answers 0 rather than failing: the watcher runs beside a run it
# does not own, and it must never be the thing that takes the run down (L71).
assert_eq "a missing log reads as no progress rather than an error" \
  "0" "$(progress_count "${TMP_DIR}/nothing-here.log")"
assert_eq "and as no bytes" "0" "$(log_bytes "${TMP_DIR}/nothing-here.log")"

# xcodebuild's stream carries the app's own output, which can hold bytes grep calls binary, so the
# count has to survive them. TWO progress lines rather than one, deliberately: an implementation that
# counted by PRINTING the matches would answer "Binary file ... matches", which is one line and would
# have passed a one-line fixture by coincidence.
#
# What this does NOT prove, said out loud so nobody reads more into it than it earns (L1): removing
# `-a` from the current `grep -c` call does not turn this red. Measured 2026-08-12 with /usr/bin/grep
# on this Mac, `-c` answers with a number on binary input either way, because the substitution only
# replaces printed lines. The assertion pins the requirement (the count survives binary bytes and
# stays a count of lines), not the flag.
BINARY_LOG="${TMP_DIR}/binary.log"
{
  printf 'Command line invocation:\n'
  printf 'a binary byte follows: \x00\x01\x02\n'
  printf '%s Test alpha() passed after 0.001 seconds.\n' "${PASS_MARK}"
  printf '%s Test beta() passed after 0.002 seconds.\n' "${PASS_MARK}"
} > "${BINARY_LOG}"
assert_eq "a log holding binary bytes still counts every progress line, not one sentence" \
  "2" "$(progress_count "${BINARY_LOG}")"

# ---------------------------------------------------------------------------
# The watcher's lifetime
# ---------------------------------------------------------------------------
# A watcher that outlives its run is worse than no watcher: it goes on measuring a temporary file
# nobody is writing to, so it eventually reports a stall that is guaranteed to be false, with nothing
# left on screen to attach it to. Asserted here rather than from the runner's fixture because this is
# the only place the PID is in hand: the loop is a shell function in a background subshell, so it
# carries its parent's command line and cannot be picked out of the process table by name.

WATCH_LOG="${TMP_DIR}/watched.log"
: > "${WATCH_LOG}"
TEST_STALL_LIMIT_SECONDS=1
TEST_STALL_CHECK_SECONDS=1
TEST_LOCK_NOTICE_SECONDS=1
start_progress_watch "${WATCH_LOG}"
WATCH_PID="${PROGRESS_WATCH_PID}"

assert_eq "starting a watcher records a PID to stop it by" \
  "recorded" "$(if [[ -n "${WATCH_PID}" ]]; then echo recorded; else echo "empty"; fi)"
assert_eq "and that PID is a process that is actually running" \
  "alive" "$(if kill -0 "${WATCH_PID}" 2>/dev/null; then echo alive; else echo gone; fi)"

stop_progress_watch "${WATCH_PID}"
assert_eq "stopping it really ends the process" \
  "gone" "$(if kill -0 "${WATCH_PID}" 2>/dev/null; then echo alive; else echo gone; fi)"

# It is called from the normal path AND from an EXIT trap, so the second call is the ordinary case
# rather than an error, and it must not take the script down with it under `set -e`.
stop_progress_watch "${WATCH_PID}"
assert_eq "stopping it twice is safe, which is what the EXIT trap does" "0" "$?"
stop_progress_watch ""
assert_eq "and stopping a watcher that was never started is safe too" "0" "$?"

# The defect this was actually caught by, kept as a guard because it is invisible from the code and
# expensive in exactly the place nobody looks (L1). The loop spends nearly all its life inside
# `sleep`, and killing the loop leaves that sleep running, reparented to launchd. An orphan like that
# still holds the run's stdout and stderr, so anything CAPTURING the run's output waits for it: a
# `sleep 30` outliving the run by 30 seconds is added to every single run, and the fixture that found
# it hung for two minutes rather than failing.
TEST_STALL_CHECK_SECONDS=30
start_progress_watch "${WATCH_LOG}"
SLOW_PID="${PROGRESS_WATCH_PID}"
sleep 1
SLOW_CHILDREN="$(pgrep -P "${SLOW_PID}" 2>/dev/null | tr '\n' ' ')"

# Asserted first, because everything below it is vacuous if the watcher had no child to leak.
assert_eq "a watcher mid-interval really does have a sleeping child to leave behind" \
  "has children" \
  "$(if [[ -n "${SLOW_CHILDREN// /}" ]]; then echo "has children"; else echo "none, so nothing below is proved"; fi)"

# The group is what makes stopping it whole possible, and it is invisible to every other assertion
# here: a watcher in the run's own process group starts, warns and is killed identically, and only
# fails to take its sleeping child with it. So it is asserted on the running process rather than by
# reading the source for the flag that arranges it (L281).
SLOW_PGID="$(ps -o pgid= -p "${SLOW_PID}" 2>/dev/null | tr -d ' ')"
SHELL_PGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
assert_eq "the watcher leads a process group of its own" "${SLOW_PID}" "${SLOW_PGID}"
assert_eq "which is not the run's own group, so stopping it cannot take the run with it" \
  "different" \
  "$(if [[ "${SLOW_PGID}" != "${SHELL_PGID}" ]]; then echo "different"; else echo "the same: ${SLOW_PGID}"; fi)"

STOP_STARTED_AT="${SECONDS}"
stop_progress_watch "${SLOW_PID}"
STOP_TOOK=$(( SECONDS - STOP_STARTED_AT ))

assert_eq "stopping a watcher does not wait out its 30 second interval" \
  "prompt" \
  "$(if [[ "${STOP_TOOK}" -le 3 ]]; then echo "prompt"; else echo "took ${STOP_TOOK}s"; fi)"

# WAITED for rather than sampled once (#3248). A signalled process is not yet a reaped one, and how
# wide the gap is depends on what else this Mac is doing: these children are grandchildren of this
# fixture, so nothing here can `wait` on them and launchd reaps them on its own schedule. Sampling
# once made this assertion a check on the machine's load. It failed exactly that way on 2026-08-29,
# `still alive: 20800`, with the Swift suite running beside it, and blocked a merge whose own change
# was green. The wait has a deadline, so a real leak still fails rather than hanging (L110, L524).
# shellcheck disable=SC2086
assert_pids_gone "and it leaves no sleeping orphan behind holding the run's output open" \
  ${SLOW_CHILDREN}

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All test-progress-watch checks passed."
else
  echo "${FAILURES} test-progress-watch check(s) failed."
  exit 1
fi
