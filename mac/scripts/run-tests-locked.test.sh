#!/usr/bin/env bash
set -uo pipefail

# Coverage for run-tests-locked.sh's stale_debug_test_host_pids (#632): xcodebuild test boots
# the full Debug-configuration app as an app-hosted XCTest host but never tears it down when the
# run finishes, so a leftover instance can shadow the current code in a later interactive check.
# Real-shaped `ps -eo pid=,command=` fixtures, not a live process table, since this is a pure
# text match over already-produced output.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./run-tests-locked.sh
source "${SCRIPT_DIR}/run-tests-locked.sh"
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

MIXED_OUTPUT="  501 /sbin/launchd
 1234 /Users/danielhankins-wright/Library/Developer/Xcode/DerivedData/Overture-aocrzmchreuxrpgeehcermgyhegg/Build/Products/Debug/Overture.app/Contents/MacOS/Overture
 5678 /Applications/Overture.app/Contents/MacOS/Overture
 9999 /usr/bin/xcodebuild -scheme Overture -destination platform=macOS test"
assert_equals "picks the DerivedData Debug test host, not the installed Release app or xcodebuild itself" \
  "1234" "$(stale_debug_test_host_pids "${MIXED_OUTPUT}")"

CLEAN_OUTPUT="  501 /sbin/launchd
 5678 /Applications/Overture.app/Contents/MacOS/Overture"
assert_equals "no stale Debug host means no pids" \
  "" "$(stale_debug_test_host_pids "${CLEAN_OUTPUT}")"

TWO_STALE_OUTPUT="  501 /sbin/launchd
 1234 /Users/danielhankins-wright/Library/Developer/Xcode/DerivedData/Overture-aocrzmchreuxrpgeehcermgyhegg/Build/Products/Debug/Overture.app/Contents/MacOS/Overture
 2222 /Users/danielhankins-wright/Library/Developer/Xcode/DerivedData/Overture-zzzzzzzzzzzzzzzzzzzzzzzzzzzz/Build/Products/Debug/Overture.app/Contents/MacOS/Overture"
assert_equals "multiple stale Debug hosts (e.g. an older DerivedData build) are all picked up" \
  "1234
2222" "$(stale_debug_test_host_pids "${TWO_STALE_OUTPUT}")"

echo
# --- crashed run vs failed run (#1006) ---------------------------------------------------
#
# On 2026-07-16 swift-tests on main printed `Test run with 1574 tests in 229 suites passed`
# for a ~2400-test suite, then died with `** TEST FAILED **` and an EMPTY `Failing tests:`
# list. Roughly 800 tests never executed, and the only number on screen said "passed". It took
# an hour to work out that nothing had actually failed; the host had been killed.
#
# A killed run and a failing run must never look alike. The tell is exact and needs no
# baseline: xcodebuild names every failing test under `Failing tests:`. If it says the run
# failed and names NOTHING, nothing failed. The process died.
#
# Deliberately NOT a floor on the executed-test count: the two real crashes reported 1574 and
# 2069 of ~2400, so a floor loose enough to survive normal test churn (2000) would have waved
# 2069 straight through, and a floor tight enough to catch it would need bumping on every PR
# that adds a test. A guard people routinely bump is a guard people stop reading.

# The status glyphs xcodebuild prints on these lines are omitted deliberately (the repo's style
# rule bans them, and the pre-push hook cannot tell a machine's quoted output from Dan-facing
# copy). run_outcome never reads them: it parses "Failing tests:" and the lines under it, and
# nothing else. So the fixtures stay real-shaped in the only part under test.
CRASHED_OUTPUT="Test Suite 'All tests' started
Test run with 1574 tests in 229 suites passed after 10.851 seconds.
Failing tests:
** TEST FAILED **"

REAL_FAILURE_OUTPUT="Test aThingWorks() recorded an issue at Foo.swift:12:5: Expectation failed
Failing tests:
	OvertureTests.FooTests.aThingWorks()
** TEST FAILED **"

PASSING_OUTPUT="Test run with 2400 tests in 348 suites passed after 19.462 seconds.
** TEST SUCCEEDED **"

# THE case. xcodebuild says the run failed and names no failing test, so nothing failed: the
# process was killed. This is what an hour of this session's investigation was spent decoding.
assert_equals "a killed run is reported as crashed, not failed" \
  "crashed" "$(run_outcome "${CRASHED_OUTPUT}" 65)"

# A genuine failure must NOT be relabelled as a crash, or the guard would cry wolf on every
# real red test and be turned off within a week.
assert_equals "a genuine test failure is still a failure" \
  "failed" "$(run_outcome "${REAL_FAILURE_OUTPUT}" 65)"

# A pass is a pass: exit 0 AND the "** TEST SUCCEEDED **" banner xcodebuild prints on every real pass.
assert_equals "a passing run reports nothing" \
  "" "$(run_outcome "${PASSING_OUTPUT}" 0)"

# #1252: the test HOST failing to LAUNCH (e.g. a running Debug app holds the single-instance lock) makes
# xcodebuild print "Could not launch" / "** TEST FAILED **" but EXIT 0. The old "exit 0 wins outright" rule
# waved that dead run through as a pass, so test-all.sh printed "all suites passed" having run zero tests. A
# real pass ALWAYS carries "** TEST SUCCEEDED **"; its absence at exit 0 means the run never passed.
LAUNCH_FAILURE_OUTPUT="Testing failed:
	Could not launch \"OvertureTests\"
** TEST FAILED **"
assert_equals "a test-host launch failure at exit 0 is crashed, not a silent pass" \
  "crashed" "$(run_outcome "${LAUNCH_FAILURE_OUTPUT}" 0)"

# And exit 0 with no verdict of any kind (no success banner, no failure) is likewise not a pass.
assert_equals "exit 0 with no success banner is crashed, not a pass" \
  "crashed" "$(run_outcome "some truncated output that never reached a verdict" 0)"

# Defence in depth: a non-zero exit with no xcodebuild verdict at all (an infra failure before
# the suite ran) is not a test failure either, and must not be reported as one.
assert_equals "a run that never reached the suite is crashed, not failed" \
  "crashed" "$(run_outcome "xcodebuild: error: Could not resolve package dependencies" 70)"

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All run-tests-locked.sh stale-host fixtures passed."
  exit 0
else
  echo "${FAILURES} run-tests-locked.sh stale-host fixture(s) failed."
  exit 1
fi
