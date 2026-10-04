#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains (#2501).
# shellcheck source=../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/shell-assertions.sh"

# #3875: when the test HOST dies between tests, say so, instead of leaving the next test to be blamed.
#
# WHAT IT COST. On 2026-09-13 the hosted target was run with `-test-iterations 10` and the host died 8
# times. Every crash was reported against `FeltWaitCostTests.measureWhatAPressCosts`, which in that
# configuration is a guard on an unset environment variable, a print and a return: it had not executed a
# line of its own body. The crash reports say so plainly and the run's own output does not, because the
# triggered stack holds no Overture test code at all, only XCTest's between-tests enumeration wait.
#
# The consistency is what makes it misleading rather than merely unhelpful: a test that returns instantly
# is the first quiet moment after the preceding heavy test tears down, so the same innocent test is named
# every time, which reads exactly like a reproducible fault in it. Two sessions investigated it.
#
# The runner already keeps eleven outcomes apart and refuses to call an empty run a pass. A crash between
# tests is a further cause it does not yet name, and today it is rendered as a fifth thing it is not: a
# specific test failing (L11, L98).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./run-tests-locked.sh
source "${SCRIPT_DIR}/run-tests-locked.sh"
set +e

FAILURES=0

# Swift Testing's own result markers, built from their UTF-8 BYTES rather than written literally.
# The pre-push style gate forbids those characters in new lines and is right to: it cannot tell a line
# USING one from a line that has to NAME one. `printf` with byte escapes keeps this file free of any
# literal marker while still producing the real output shape, which is what the parser under test reads.
# Bytes rather than `$'\u2714'`, because that form needs bash 4.2 and macOS ships 3.2.
TICKMARK="$(printf '\xe2\x9c\x94')"
DIAMONDMARK="$(printf '\xe2\x97\x87')"

# A real transcript's shape, trimmed: two tests complete, a third starts, the host dies, xcodebuild
# restarts. Taken from the 2026-09-13 run rather than invented, because the ORDER is the whole point.
CRASHED_RUN="$(cat <<'EOF'
TICKMARK Test aPressReallyRebuildsTheQueue() passed after 1.121 seconds.
DIAMONDMARK Test anyWriteAtAllCostsExactlyOnePass() started.
TICKMARK Test anyWriteAtAllCostsExactlyOnePass() passed after 1.130 seconds.
DIAMONDMARK Test measureWhatAPressCosts() started.

Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.

DIAMONDMARK Test somethingElse() started.
TICKMARK Test somethingElse() passed after 0.2 seconds.
EOF
)"
CRASHED_RUN="${CRASHED_RUN//TICKMARK/${TICKMARK}}"
CRASHED_RUN="${CRASHED_RUN//DIAMONDMARK/${DIAMONDMARK}}"

CLEAN_RUN="$(cat <<'EOF'
TICKMARK Test aPressReallyRebuildsTheQueue() passed after 1.121 seconds.
TICKMARK Test anyWriteAtAllCostsExactlyOnePass() passed after 1.130 seconds.
** TEST SUCCEEDED **
EOF
)"
CLEAN_RUN="${CLEAN_RUN//TICKMARK/${TICKMARK}}"

report="$(crash_restart_report "${CRASHED_RUN}")"

assert_contains "it says the host DIED rather than a test failing" \
  "${report}" "died"
assert_contains "it says how many times" \
  "${report}" "1"
assert_contains "it names the last test to COMPLETE, which is the trustworthy one" \
  "${report}" "anyWriteAtAllCostsExactlyOnePass"
assert_contains "it names the test that was merely CURRENT" \
  "${report}" "measureWhatAPressCosts"
# The whole point: the named test must be marked as an attribution, not a finding. Without this the
# report is just a second way of blaming the same innocent test.
assert_contains "it marks the current test as an attribution rather than a finding" \
  "${report}" "attribution"
assert_contains "it points at the only real evidence, the crash report" \
  "${report}" "DiagnosticReports"

# SILENT ON A CLEAN RUN. A report that speaks on every run is one people stop reading, and this one
# would then be noise on the ~9,600-test runs that make up every push (L36).
clean="$(crash_restart_report "${CLEAN_RUN}")"
assert_empty "it says NOTHING when the host did not die" "${clean}"

echo
# --- #4444: a host crash that names the test in flight is still a host crash, and is retried ---------
#
# When the host dies, xcodebuild restarts it and names the test that was running as a failure ("Test
# crashed with signal trap"), so `run_outcome` counted one named failure and called the run "failed",
# which is never retried. In September 2026, 30 of the 77 red `swift-tests` jobs were exactly this, all
# against `HostedWindowsAreReleasedTests.whichPartOfAHostedTestSurvivesIt()`, on 29 branches, and none was
# retried. The shape below is run 37212772398 (2026-10-04, branch phase3-slice-e1-placements-v2), trimmed:
# the test starts, the host dies, xcodebuild restarts it, the rest passes, and the `Failing tests:` block
# names only the test that was in flight.
HOST_CRASH_RUN="$(cat <<'EOF'
TICKMARK Test aStoreChangeStillReachesAQueueThatNoLongerQueriesTheStore() passed after 0.061 seconds.
DIAMONDMARK Suite "A hosted test releases its view tree (#3874)" started.
DIAMONDMARK Test whichPartOfAHostedTestSurvivesIt() started.
2026-10-04 15:55:29.868427+0000 Overture[62640:152349] [Common] Unable to obtain a task name port right for pid 165: (os/kern) failure (0x5)

Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.

DIAMONDMARK Test aHealthyWatchDrawsNothing() started.
TICKMARK Test aHealthyWatchDrawsNothing() passed after 0.100 seconds.
TICKMARK Test run with 270 tests in 51 suites passed after 46.173 seconds.

Failing tests:
	HostedWindowsAreReleasedTests.whichPartOfAHostedTestSurvivesIt()

** TEST FAILED **
EOF
)"
HOST_CRASH_RUN="${HOST_CRASH_RUN//TICKMARK/${TICKMARK}}"
HOST_CRASH_RUN="${HOST_CRASH_RUN//DIAMONDMARK/${DIAMONDMARK}}"

assert_equals "the test in flight when the host restarted is read out of the log" \
  "whichPartOfAHostedTestSurvivesIt()" "$(tests_in_flight_at_restart "${HOST_CRASH_RUN}")"
assert_equals "a run whose ONLY named failure is the test the host died under is a host crash" \
  "host-crashed" "$(run_outcome "${HOST_CRASH_RUN}" 65)"
assert_equals "and a host crash is retried once" \
  "retry" "$(should_retry "host-crashed" 1 2)"
assert_equals "but only once: the cap holds" \
  "" "$(should_retry "host-crashed" 2 2)"
assert_empty "a host crash with a named test does not ask the pure suite, which needs no host" \
  "$(should_probe_pure_suite "host-crashed")"

# THE OTHER DIRECTION (L1, L104): a genuine assertion failure must stay "failed" and never be retried,
# or the retry papers over a real red. Same crash, plus a real failure in a test that FINISHED.
REAL_PLUS_CRASH="${HOST_CRASH_RUN/	HostedWindowsAreReleasedTests.whichPartOfAHostedTestSurvivesIt()/	HostedWindowsAreReleasedTests.whichPartOfAHostedTestSurvivesIt()
	WatchGapLineTests.aHealthyWatchDrawsNothing()}"
assert_equals "a real failure beside the crash keeps the run failed" \
  "failed" "$(run_outcome "${REAL_PLUS_CRASH}" 65)"

# A named failure with no restart at all is an ordinary failure, whatever its name.
NO_RESTART="${HOST_CRASH_RUN/Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches./}"
assert_equals "with no restart line a named failure is an ordinary failure" \
  "failed" "$(run_outcome "${NO_RESTART}" 65)"

# A test that had already FINISHED before the restart was not in flight, so naming it is a real failure.
FINISHED_FIRST="${HOST_CRASH_RUN/	HostedWindowsAreReleasedTests.whichPartOfAHostedTestSurvivesIt()/	StoreLiveTests.aStoreChangeStillReachesAQueueThatNoLongerQueriesTheStore()}"
assert_equals "a named test that finished before the restart is a real failure, not the crash" \
  "failed" "$(run_outcome "${FINISHED_FIRST}" 65)"

# The crashed run with nothing named keeps its old outcome: this change narrows nothing.
assert_equals "a crash that names nothing is still crashed" \
  "crashed" "$(run_outcome "Restarting after unexpected exit, crash, or test timeout
Failing tests:
** TEST FAILED **" 65)"

# Never a silent pass: a run that passes on its retry says so, naming what the first attempt met.
retry_note="$(passed_on_retry_report "host-crashed" "HostedWindowsAreReleasedTests.whichPartOfAHostedTestSurvivesIt()")"
assert_contains "a pass on the retry says it was a retry" "${retry_note}" "PASSED ON A RETRY"
assert_contains "and names the test the host died under" "${retry_note}" "whichPartOfAHostedTestSurvivesIt"
assert_empty "a first time pass says nothing about retries" "$(passed_on_retry_report "" "")"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "run-tests-locked-crash-report.test.sh: all assertions passed"
  exit 0
else
  echo "run-tests-locked-crash-report.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
