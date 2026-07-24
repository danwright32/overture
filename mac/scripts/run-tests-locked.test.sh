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
# --- pre-flight blocker detection (#1257) ------------------------------------------------
#
# A running Debug Overture that run-debug.sh launched from mac/build holds the single-instance lock
# (LSMultipleInstancesProhibited), so the test host cannot launch and the run dies AFTER a full build
# (#1252 detects that; #1257 prevents it). blocking_debug_app_pids finds exactly that instance so main
# can stop before building. Deliberately NARROWER than stale_debug_test_host_pids in one direction and
# WIDER in another: it must NOT flag the DerivedData test host (the runner's OWN spawn, safe to kill,
# handled separately), and it MUST flag the mac/build instance (Dan's, which must never be auto-killed).

BUILD_DEBUG_OUTPUT="  501 /sbin/launchd
 3333 /Users/danielhankins-wright/Non-icloudDocuments/Photography Assets/Dan Wright Photography/Marketing/Outreach/Overture/mac/build/Build/Products/Debug/Overture.app/Contents/MacOS/Overture
 5678 /Applications/Overture.app/Contents/MacOS/Overture"
assert_equals "a mac/build Debug instance (run-debug.sh) is flagged as a blocker" \
  "3333" "$(blocking_debug_app_pids "${BUILD_DEBUG_OUTPUT}")"

DERIVED_ONLY_OUTPUT="  501 /sbin/launchd
 1234 /Users/danielhankins-wright/Library/Developer/Xcode/DerivedData/Overture-aocrzmchreuxrpgeehcermgyhegg/Build/Products/Debug/Overture.app/Contents/MacOS/Overture"
assert_equals "the DerivedData test host is the runner's own and is NOT a pre-flight blocker" \
  "" "$(blocking_debug_app_pids "${DERIVED_ONLY_OUTPUT}")"

assert_equals "the installed Release app never blocks a test run" \
  "" "$(blocking_debug_app_pids "  5678 /Applications/Overture.app/Contents/MacOS/Overture")"

assert_equals "nothing running Debug means no blocker" \
  "" "$(blocking_debug_app_pids "  501 /sbin/launchd")"

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

echo
# --- retry a flaky host crash once (#1331) ------------------------------------------------
#
# The self-hosted swift-tests runner intermittently crashes the test HOST mid-run ("Restarting
# after unexpected exit" / the host could not launch). On a merge commit's push-CI this reds main
# even though the PR passed and the suite passes locally, and merge-when-green then refuses the next
# PR until someone reruns by hand. A host crash (run_outcome == "crashed": the run died, no NAMED
# test failure) is retried ONCE. A genuine failure (named tests) is NEVER retried, or the guard would
# paper over real reds. A pass is never retried either.

assert_equals "a first host crash is retried" \
  "retry" "$(should_retry "crashed" 1 2)"

assert_equals "a second host crash is NOT retried (one retry only)" \
  "" "$(should_retry "crashed" 2 2)"

assert_equals "a genuine test failure is never retried" \
  "" "$(should_retry "failed" 1 2)"

assert_equals "a pass is never retried" \
  "" "$(should_retry "" 1 2)"

echo
# --- the wiring, not the functions (#1459) ------------------------------------------------
#
# Every assertion above passes while the wrapper still tells you the exact opposite of the truth,
# because run_outcome and should_retry were never the broken part: main handed run_outcome the
# WRONG exit code. `xcodebuild ... | tee "${output_file}" || true` followed by
# `test_exit_code="${PIPESTATUS[0]}"` reads 0 on precisely the runs where it should read 65. Under
# `set -euo pipefail` a red xcodebuild makes the whole pipeline fail, so `true` runs, and `true` is
# itself a pipeline, so it overwrites PIPESTATUS with (0):
#
#   bash -c '(exit 65) | tee /dev/null || true; echo ${PIPESTATUS[0]}'                     -> 65
#   bash -c 'set -euo pipefail; (exit 65) | tee /dev/null || true; echo ${PIPESTATUS[0]}'  ->  0
#
# So every genuine failure took run_outcome's exit-0 branch, found no success banner, and came back
# "crashed": the #1331 flake retry doubled the runtime of every red run, the real `Failing tests:`
# list was buried under a message about a Debug app holding a lock, and the run signed off with
# "if it passes, the code was never the problem" while the code WAS the problem. The exact inverse
# of what #1006 built this distinction for.
#
# These drive the REAL script end to end with flock, xcodebuild and ps stubbed on PATH, because the
# defect lives in the seam between the functions and nothing that tests a function in isolation can
# see it.

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected output to contain: ${needle}"
    echo "  actual output: ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected output NOT to contain: ${needle}"
    echo "  actual output: ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

# Runs the real run-tests-locked.sh with flock, xcodebuild and ps stubbed ahead of the real ones on
# PATH, so main's whole path executes without building anything or reading this Mac's process table.
# Prints the script's combined output with a final "exit=<code>" line.
run_wrapper_with_stub_xcodebuild() {
  local xcodebuild_output="$1" xcodebuild_exit="$2"
  local bin_dir output code

  bin_dir="$(mktemp -d)"

  # flock's real job is serialising xcodebuild across worktrees, which is irrelevant here; once it
  # holds the lock it execs the rest of its arguments, and so does this.
  cat > "${bin_dir}/flock" <<'STUB'
#!/usr/bin/env bash
shift
exec "$@"
STUB

  # A process table with nothing Overture-shaped in it, so the pre-flight neither kills anything nor
  # stops for a blocking Debug app.
  cat > "${bin_dir}/ps" <<'STUB'
#!/usr/bin/env bash
echo "  501 /sbin/launchd"
STUB

  cat > "${bin_dir}/xcodebuild" <<STUB
#!/usr/bin/env bash
cat <<'XCODEBUILD_OUTPUT'
${xcodebuild_output}
XCODEBUILD_OUTPUT
exit ${xcodebuild_exit}
STUB

  chmod +x "${bin_dir}/flock" "${bin_dir}/ps" "${bin_dir}/xcodebuild"

  output="$(PATH="${bin_dir}:${PATH}" "${SCRIPT_DIR}/run-tests-locked.sh" 2>&1)"
  code=$?
  rm -rf "${bin_dir}"
  printf '%s\nexit=%s\n' "${output}" "${code}"
}

# THE case. Two deliberately-red guards on #1451 came out of this wrapper labelled a crashed run.
REAL_FAILURE_RUN="$(run_wrapper_with_stub_xcodebuild "${REAL_FAILURE_OUTPUT}" 65)"

assert_equals "a named test failure exits with xcodebuild's own code, not the crash path's 1" \
  "exit=65" "$(tail -n 1 <<< "${REAL_FAILURE_RUN}")"

assert_not_contains "a named test failure is never retried" \
  "Retrying once" "${REAL_FAILURE_RUN}"

assert_not_contains "a named test failure is never dressed up as a run that died" \
  "the test run CRASHED" "${REAL_FAILURE_RUN}"

# The other half of the same claim: fixing the above must not quietly disable #1331's flake retry.
CRASH_RUN="$(run_wrapper_with_stub_xcodebuild "${CRASHED_OUTPUT}" 65)"

assert_contains "a run that died with nothing named is still retried once" \
  "Retrying once" "${CRASH_RUN}"

assert_contains "a run that died with nothing named still says so" \
  "the test run CRASHED" "${CRASH_RUN}"

# And a pass still passes, silently.
PASSING_RUN="$(run_wrapper_with_stub_xcodebuild "${PASSING_OUTPUT}" 0)"

assert_equals "a passing run exits 0" \
  "exit=0" "$(tail -n 1 <<< "${PASSING_RUN}")"

assert_not_contains "a passing run is never retried" \
  "Retrying once" "${PASSING_RUN}"

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All run-tests-locked.sh stale-host fixtures passed."
  exit 0
else
  echo "${FAILURES} run-tests-locked.sh stale-host fixture(s) failed."
  exit 1
fi
