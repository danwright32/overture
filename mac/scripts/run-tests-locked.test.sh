#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/shell-assertions.sh"

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
OWN_DERIVED="/Users/danielhankins-wright/Library/Developer/Xcode/DerivedData/Overture-aocrzmchreuxrpgeehcermgyhegg"
OTHER_DERIVED="/Users/danielhankins-wright/Library/Developer/Xcode/DerivedData/Overture-zzzzzzzzzzzzzzzzzzzzzzzzzzzz"
assert_equals "picks the DerivedData Debug test host, not the installed Release app or xcodebuild itself" \
  "1234" "$(stale_debug_test_host_pids "${MIXED_OUTPUT}" "${OWN_DERIVED}")"

CLEAN_OUTPUT="  501 /sbin/launchd
 5678 /Applications/Overture.app/Contents/MacOS/Overture"
assert_equals "no stale Debug host means no pids" \
  "" "$(stale_debug_test_host_pids "${CLEAN_OUTPUT}" "${OWN_DERIVED}")"

TWO_STALE_OUTPUT="  501 /sbin/launchd
 1234 /Users/danielhankins-wright/Library/Developer/Xcode/DerivedData/Overture-aocrzmchreuxrpgeehcermgyhegg/Build/Products/Debug/Overture.app/Contents/MacOS/Overture
 2222 /Users/danielhankins-wright/Library/Developer/Xcode/DerivedData/Overture-zzzzzzzzzzzzzzzzzzzzzzzzzzzz/Build/Products/Debug/Overture.app/Contents/MacOS/Overture"
assert_equals "multiple stale Debug hosts under THIS run's DerivedData are all picked up" \
  "1234" "$(stale_debug_test_host_pids "${TWO_STALE_OUTPUT}" "${OWN_DERIVED}")"

# --- #1671: a run only ever kills hosts it can attribute to itself -----------------------
#
# The kill sweeps run OUTSIDE the flock, one before the lock is taken and one after it is released, so
# with two sessions on this Mac a finishing run can reach a host that a run holding the lock has just
# launched. The victim dies with no named test failure, which is the exact shape `run_outcome` calls
# "crashed" and `should_retry` retries as a known flake, so the retry meant to absorb a real flake also
# hides this one and nothing points outside the victim's own code.
assert_equals "another session's live test host is never a candidate" \
  "2222" "$(stale_debug_test_host_pids "${TWO_STALE_OUTPUT}" "${OTHER_DERIVED}")"

# The fail-safe direction. This function only ever KILLS, so a scope it could not resolve must leave
# every process alone rather than fall back to matching all of them (L42).
assert_equals "an unresolved scope kills nothing at all" \
  "" "$(stale_debug_test_host_pids "${TWO_STALE_OUTPUT}" "")"

echo
# --- #2195: a truncated run must not read as an ordinary failure -------------------------
#
# Three consecutive runs on 2026-08-06 reported 4837, 4836 and 3932 tests against main's 5503, each
# naming a DIFFERENT innocent bystander that happened to be in flight when the process died. Between
# 600 and 1,500 tests never executed and nothing said so.

# The real banner is prefixed with a check glyph, dropped here because the matcher never looks at it and
# the repo's style gate forbids the literal character in a tracked file.
COMBINED_OUTPUT='Test Suite started
Test run with 5428 tests in 771 suites passed after 89.2 seconds.
Test run with 245 tests in 41 suites passed after 3.9 seconds.
** TEST SUCCEEDED **'
assert_equals "the count sums every target the combined scheme reports" \
  "5673" "$(executed_test_count "${COMBINED_OUTPUT}")"

assert_equals "a run that died before any suite reported has no count to give" \
  "" "$(executed_test_count 'xcodebuild: error: nothing ran')"

assert_equals "a run 29 percent short says so, by number" \
  "this run executed 3932 tests, 1571 fewer than the 5503 the last green run on this Mac ran. The result is NOT trustworthy: the process almost certainly died partway through, and any test named below was merely in flight when it did, not the cause." \
  "$(truncated_report 3932 5503)"

assert_equals "and so does one 12 percent short" \
  "this run executed 4836 tests, 667 fewer than the 5503 the last green run on this Mac ran. The result is NOT trustworthy: the process almost certainly died partway through, and any test named below was merely in flight when it did, not the cause." \
  "$(truncated_report 4836 5503)"

# Ordinary churn is not a short run. The guard exists to catch a process that STOPPED, and one tight
# enough to fire on a branch that removes a suite is one that gets ignored (the same objection
# run_outcome records against a hand-maintained floor).
assert_equals "a branch that removes a few tests is not called truncated" \
  "" "$(truncated_report 5450 5503)"

assert_equals "a run that ADDS tests is not called truncated" \
  "" "$(truncated_report 5521 5503)"

# No baseline is no claim. The first green run on a Mac records one; until then the guard must say
# nothing rather than guess in either direction.
assert_equals "no baseline yet means no verdict" \
  "" "$(truncated_report 3932 "")"

assert_equals "a zero baseline is treated as no baseline, not as everything being short" \
  "" "$(truncated_report 3932 0)"

echo
# --- #2317: a run that executed NOTHING is not a pass -------------------------------------
#
# A scoped run whose -only-testing: path matches nothing prints "** TEST SUCCEEDED **" and exits 0
# having run zero tests. Hit again on 2026-08-08 while verifying #1994: the scope named one test that
# did not resolve, reported success against a deliberately stale file that should have failed it, and
# the same scope at suite level then failed correctly.
#
# The case where it bites is exactly the case where nobody is suspicious, because the run said it
# passed. Since #1347 this run is the ONLY thing verifying the Mac app before it reaches main.
#
# Distinct from SHORT RUN, which is about a run that started and died partway. This is a run that never
# started anything at all, and the two need different sentences because they need different responses.

assert_equals "a reported pass that executed no tests is refused" \
  "this run reported success but executed NO tests at all. Nothing was verified. A -only-testing: scope that matches nothing (a wrong suite or test name, or a @Suite display name that differs from its Swift type name) does exactly this: xcodebuild prints ** TEST SUCCEEDED ** and exits 0." \
  "$(nothing_executed_report 0 "")"

assert_equals "and so is one that reported a count of zero" \
  "this run reported success but executed NO tests at all. Nothing was verified. A -only-testing: scope that matches nothing (a wrong suite or test name, or a @Suite display name that differs from its Swift type name) does exactly this: xcodebuild prints ** TEST SUCCEEDED ** and exits 0." \
  "$(nothing_executed_report 0 0)"

# A run that executed tests is not this failure, however few it ran. One test is a scope that resolved.
assert_equals "a run that executed even one test is not called empty" \
  "" "$(nothing_executed_report 0 1)"

assert_equals "a full green run is not called empty" \
  "" "$(nothing_executed_report 0 6219)"

# A run that already failed says why on its own path. Adding this sentence to a red run would put a
# second, wrong explanation in front of whoever is reading the real failure: a build failure and a dead
# host both reach here with no count, and neither is a scope that matched nothing.
assert_equals "a failing run is left to its own explanation" \
  "" "$(nothing_executed_report 1 "")"

assert_equals "a crashed run with no count is left to its own explanation" \
  "" "$(nothing_executed_report 65 "")"

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

# Runs the real run-tests-locked.sh with flock, xcodebuild, ps and log stubbed ahead of the real ones
# on PATH, so main's whole path executes without building anything, reading this Mac's process table,
# or dumping its OS log. Prints the script's combined output, then a "logcalls=<n>" line counting the
# `log` invocations (#1972: only a dead run may pay for one), then a final "exit=<code>" line.
#
# #2321: the fourth argument is where the run may keep a diagnostic it cannot print in full. It
# defaults inside the throwaway bin_dir, so a fixture is structurally unable to write into the real
# one (L2); pass a directory of your own when the assertion is about what survives the run.
run_wrapper_with_stub_xcodebuild() {
  local xcodebuild_output="$1" xcodebuild_exit="$2" log_output="${3:-}" diagnostics_dir="${4:-}"
  local bin_dir output code log_calls

  bin_dir="$(mktemp -d)"
  [[ -n "${diagnostics_dir}" ]] || diagnostics_dir="${bin_dir}/diagnostics"

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

  # Records every invocation, so a run that must not read the OS log can be shown not to (an
  # assertion on the printed output alone cannot tell "never called" from "called and found
  # nothing"). Echoes back the fixture dump the real `log show` would have produced.
  cat > "${bin_dir}/log" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "${bin_dir}/log-calls"
cat <<'LOG_OUTPUT'
${log_output}
LOG_OUTPUT
STUB

  chmod +x "${bin_dir}/flock" "${bin_dir}/ps" "${bin_dir}/xcodebuild" "${bin_dir}/log"

  # #2195: a throwaway baseline. The stub reports a handful of tests, so against the real one every
  # wrapper run here would read as a catastrophically short run, and a fixture must never write to the
  # file the real gate is measured against either (L2).
  local baseline_file="${bin_dir}/baseline"
  output="$(PATH="${bin_dir}:${PATH}" OVERTURE_TEST_BASELINE_FILE="${baseline_file}" \
    OVERTURE_TEST_DIAGNOSTICS_DIR="${diagnostics_dir}" \
    "${SCRIPT_DIR}/run-tests-locked.sh" 2>&1)"
  code=$?
  log_calls="$(grep -c . "${bin_dir}/log-calls" 2>/dev/null || echo 0)"
  rm -rf "${bin_dir}"
  printf '%s\nlogcalls=%s\nexit=%s\n' "${output}" "${log_calls}" "${code}"
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

echo
# --- a build failure is not a flaky host (#1465) ------------------------------------------
#
# `crashed` was carrying two different things. It means "the run died without naming a failing test",
# and a COMPILE failure has exactly that shape: xcodebuild exits 65, prints "** TEST FAILED **", and
# names no failing test because nothing ever ran. So a Swift syntax error was retried as a #1331 host
# flake, costing two full builds, and then signed off with "if it passes, the code was never the
# problem" printed over a list of compiler errors. Seen live on 2026-07-24 while spiking #1412 and
# again while writing this: the error list appeared twice, once per attempt.
#
# A run that never reached the suite is genuinely not a test failure, but it is not a flake either,
# and only a flake is worth retrying.
#
# Captured from a REAL run (a deliberate type error added to a test file, 2026-07-24), not invented,
# so the tells under test are the ones xcodebuild actually prints.
BUILD_FAILURE_OUTPUT="/Users/dan/Overture/mac/OvertureTests/PerformerMatchVisibilityTests.swift:214:46: error: cannot convert value of type 'String' to specified type 'Int'

Testing failed:
	Cannot convert value of type 'String' to specified type 'Int'
	Testing cancelled because the build failed.

** TEST FAILED **


The following build commands failed:
	SwiftCompile normal arm64 /Users/dan/Overture/mac/OvertureTests/PerformerMatchVisibilityTests.swift (in target 'OvertureTests' from project 'Overture')
(1 failure)"

assert_equals "code that did not compile is a build failure, not a dead host" \
  "build-failed" "$(run_outcome "${BUILD_FAILURE_OUTPUT}" 65)"

assert_equals "a build failure is never retried" \
  "" "$(should_retry "build-failed" 1 2)"

# The false positive that makes a naive `error:` grep wrong, and the reason the tell is the compiler's
# own file:line:column shape (and its build-commands banner) rather than the word alone. Every real run
# of this suite prints CoreData noise carrying "error:", and a host that dies mid-run prints it too.
# Reading that as a build failure would kill #1331's retry for the exact flake it exists to absorb.
CRASH_WITH_ERROR_NOISE="Test Suite 'All tests' started
2026-07-24 14:48:55.738 Overture[37030:38151440] [error] CoreData: error: Executing as effective user 501
Test run with 1574 tests in 229 suites passed after 10.851 seconds.
Failing tests:
** TEST FAILED **"

assert_equals "a dead host whose log carries CoreData error noise is still a crash" \
  "crashed" "$(run_outcome "${CRASH_WITH_ERROR_NOISE}" 65)"

# And the infra failure that never reached a compiler stays a crash, so this change narrows nothing
# it did not mean to: a dependency resolution that failed once is still worth one more try.
assert_equals "an infra failure with no compiler errors is still a crash" \
  "crashed" "$(run_outcome "xcodebuild: error: Could not resolve package dependencies" 70)"

# End to end, which is where the cost actually showed up: two builds and a misleading sign-off.
BUILD_FAILURE_RUN="$(run_wrapper_with_stub_xcodebuild "${BUILD_FAILURE_OUTPUT}" 65)"

assert_equals "a build failure reports the compiler errors exactly once" \
  "1" "$(grep -c "error: cannot convert value of type" <<< "${BUILD_FAILURE_RUN}")"

assert_not_contains "a build failure is not retried as a flaky host" \
  "Retrying once" "${BUILD_FAILURE_RUN}"

assert_not_contains "a build failure is not dressed up as a run that died" \
  "the test run CRASHED" "${BUILD_FAILURE_RUN}"

assert_not_contains "a build failure is never signed off as not being the code's fault" \
  "the code was never the problem" "${BUILD_FAILURE_RUN}"

assert_contains "a build failure says the code did not compile" \
  "the code did not COMPILE, so no test ran" "${BUILD_FAILURE_RUN}"

assert_equals "a build failure exits with xcodebuild's own code" \
  "exit=65" "$(tail -n 1 <<< "${BUILD_FAILURE_RUN}")"

# #1967: when the run DIED (the host crashed), the pure suite's verdict is still knowable, because the
# pure suite does not need the app at all. Measured on 2026-08-02 with a deliberate fatalError in
# OvertureApp.init: the OvertureCore scheme reported "4802 tests passed" and exit 0 while the app could
# not start. So a crash is exactly the case where the runner should go and ask, instead of printing one
# red verdict over a suite that actually passed.
#
# A real FAILURE is never probed: named tests failed, the answer is already known, and re-running the
# pure suite would only bury the list. Nor is a build failure, which did not compile in the first place.
assert_equals "a crashed run probes the pure suite, because its verdict is still knowable" \
  "probe" "$(should_probe_pure_suite crashed)"

assert_equals "a genuine failure is never probed; the failing tests are already named" \
  "" "$(should_probe_pure_suite failed)"

assert_equals "a build failure is never probed; nothing compiled, so nothing ran" \
  "" "$(should_probe_pure_suite build-failed)"

assert_equals "a pass is never probed" \
  "" "$(should_probe_pure_suite "")"

echo
# --- name the cause from the host's own log (#1972) ----------------------------------------
#
# A crash said WHICH kind of red it was (#1006) but never WHY, and the causes it printed were a
# guess: a hardcoded "usual causes" list naming a Debug app holding the single-instance lock and an
# overlapping run on this Mac. On 2026-08-01 the real cause was neither. The app's menu bar item had
# been removed, which terminates a MenuBarExtra app and so its test host (#1966), and the wrong hint
# sent hours of elimination in the wrong direction (clean main, deleted DerivedData, store locks,
# disk space, crash reports, stale LaunchServices registrations, a full restart).
#
# The reason was in the operating system's own log the whole time, two lines deep. These cover
# getting at it: which process to ask about, and cutting the answer down to the lines that name a
# cause.

# The host logs its own PID in every line it prints through xcodebuild, in the shape
# `Overture[37030:38151440]`. That is the only place the dead process's identity survives, since by
# the time the run is declared dead the process is gone and cannot be found in the process table.
HOST_PID_OUTPUT="Test Suite 'All tests' started
2026-08-01 14:48:55.738 Overture[37030:38151440] [error] CoreData: error: Executing as effective user 501
Failing tests:
** TEST FAILED **"
assert_equals "the dead host's PID is read out of its own log prefix" \
  "37030" "$(host_pid_from_output "${HOST_PID_OUTPUT}")"

# The case in this issue's title: the host died BEFORE it started, so it never logged a line and
# there is no PID to find. That must be empty rather than a fabricated one, because the predicate
# built from it decides what the log is asked about.
NEVER_LAUNCHED_OUTPUT="Testing failed:
	Could not launch \"OvertureTests\"
** TEST FAILED **"
assert_equals "a host that never launched leaves no PID" \
  "" "$(host_pid_from_output "${NEVER_LAUNCHED_OUTPUT}")"

# xcodebuild relaunches the host after an unexpected exit, so one attempt's output can carry two
# PIDs. The one that matters is the last, which is the process whose death ended the run.
RELAUNCHED_OUTPUT="2026-08-01 14:48:55.738 Overture[37030:38151440] [error] CoreData: noise
Restarting after unexpected exit, crash, or test timeout in FooTests
2026-08-01 14:49:20.110 Overture[37044:38151999] [error] CoreData: noise
Failing tests:
** TEST FAILED **"
assert_equals "after a relaunch the PID asked about is the host that actually died" \
  "37044" "$(host_pid_from_output "${RELAUNCHED_OUTPUT}")"

# Ask the log about the exact process when we know which one it was, and fall back to the app by
# name when the host never got far enough to say. Never a PID we did not observe.
assert_equals "a known PID is asked about by PID" \
  "processID == 37030" "$(host_log_predicate "37030")"

assert_equals "with no PID the log is asked about the app by name" \
  'process == "Overture"' "$(host_log_predicate "")"

# The decisive pair from 2026-08-01, in `log show` line shape, buried in the framework chatter that
# a --debug --info dump of a ~90 second run actually produces. Printing the dump whole would bury
# the two lines that name the cause, which is the same defect as printing nothing.
REAL_LOG_OUTPUT='2026-08-01 14:48:50.100000-0400 0x1a2b Default 0x0 37030 0 Overture: (CoreFoundation) [com.apple.CFBundle] Bundle loaded
2026-08-01 14:48:51.200000-0400 0x1a2c Default 0x0 37030 0 Overture: (HIToolbox) [com.apple.HIToolbox] menu bar layout changed
2026-08-01 14:48:55.738000-0400 0x1a2d Default 0x0 37030 0 Overture: (AppKit) [com.apple.AppKit:StatusBar] 0 terminating on removal
2026-08-01 14:48:55.740000-0400 0x1a2e Default 0x0 37030 0 Overture: (AppKit) [com.apple.AppKit:Application] terminate:'

LOG_EVIDENCE="$(host_log_evidence "${REAL_LOG_OUTPUT}")"

assert_contains "the status bar line that names the cause is kept" \
  "[com.apple.AppKit:StatusBar] 0 terminating on removal" "${LOG_EVIDENCE}"

assert_contains "the termination line that names the cause is kept" \
  "[com.apple.AppKit:Application] terminate:" "${LOG_EVIDENCE}"

assert_not_contains "ordinary framework chatter is dropped" \
  "Bundle loaded" "${LOG_EVIDENCE}"

# A privacy denial and an unopenable store are the other two causes seen here (#663 refuses a
# foreign file at the store path, and a missing TCC grant kills calendar and Gmail access), so the
# filter must keep them too rather than only the one crash it was written from.
OTHER_CAUSES_LOG='2026-08-02 09:00:00.000000-0400 0x1 Default 0x0 41000 0 Overture: (TCC) [com.apple.TCC:access] TCC deny kTCCServiceCalendar
2026-08-02 09:00:01.000000-0400 0x2 Default 0x0 41000 0 Overture: (Overture) store unavailable: refusing to open a foreign file'

OTHER_EVIDENCE="$(host_log_evidence "${OTHER_CAUSES_LOG}")"

assert_contains "a privacy denial is kept" "TCC deny kTCCServiceCalendar" "${OTHER_EVIDENCE}"
assert_contains "an unopenable store is kept" "store unavailable" "${OTHER_EVIDENCE}"

# Nothing matching means nothing to print, so the caller can say the log named no cause instead of
# printing an empty block under a heading promising evidence.
assert_equals "a log naming no cause yields no evidence" \
  "" "$(host_log_evidence '2026-08-01 14:48:50.100000-0400 0x1a2b Default 0x0 37030 0 Overture: (CoreFoundation) [com.apple.CFBundle] Bundle loaded')"

# And a log that matches thousands of times is capped, or the two useful lines scroll away exactly
# as they would have in the raw dump.
MANY_MATCHES="$(for i in $(seq 1 120); do echo "line ${i} terminating"; done)"
assert_equals "the evidence is capped at the last 40 lines" \
  "40" "$(host_log_evidence "${MANY_MATCHES}" | grep -c .)"

assert_contains "the cap keeps the LAST lines, which are the ones nearest the death" \
  "line 120 terminating" "$(host_log_evidence "${MANY_MATCHES}")"

echo
# --- the wiring: only a dead run asks the OS log (#1972) -----------------------------------
#
# `log show --debug --info` over the window of a full test run is slow and produces thousands of
# lines, so a run that did not die must never pay for it. The functions above are all correct while
# main either never calls them or calls them on every run, and neither is visible from a fixture
# that tests a function in isolation. These drive the real script with `log` stubbed alongside
# flock, xcodebuild and ps, and count the calls.

CRASH_WITH_PID_RUN="$(run_wrapper_with_stub_xcodebuild "${CRASH_WITH_ERROR_NOISE}" 65 "${REAL_LOG_OUTPUT}")"

assert_contains "a dead run asks the OS log about the host that died" \
  "logcalls=1" "${CRASH_WITH_PID_RUN}"

assert_contains "a dead run prints the line that names the cause" \
  "[com.apple.AppKit:StatusBar] 0 terminating on removal" "${CRASH_WITH_PID_RUN}"

assert_contains "the log is asked about the dead host's own PID" \
  "processID == 37030" "${CRASH_WITH_PID_RUN}"

# THE regression. A hint the script cannot support is worse than no hint: this exact sentence sent
# the 2026-08-01 investigation at a Debug app and an overlapping run when the cause was neither.
assert_not_contains "a dead run no longer guesses at usual causes" \
  "Usual causes" "${CRASH_WITH_PID_RUN}"

# When the log names nothing, say so and hand over the command, rather than printing an empty block
# or falling back to the guess this change exists to remove.
SILENT_LOG_RUN="$(run_wrapper_with_stub_xcodebuild "${CRASH_WITH_ERROR_NOISE}" 65 "nothing here names a cause")"

assert_contains "a log that names no cause says so" \
  "named no cause" "${SILENT_LOG_RUN}"

assert_contains "and hands over the command to read it in full" \
  "log show --last" "${SILENT_LOG_RUN}"

# The three runs that must never pay for it. A pass is the common case and must stay silent; a
# named test failure already knows what failed; a build failure never started a host at all, so
# there is no host log to read.
assert_contains "a passing run never asks the OS log" \
  "logcalls=0" "$(run_wrapper_with_stub_xcodebuild "${PASSING_OUTPUT}" 0 "${REAL_LOG_OUTPUT}")"

assert_contains "a named test failure never asks the OS log" \
  "logcalls=0" "$(run_wrapper_with_stub_xcodebuild "${REAL_FAILURE_OUTPUT}" 65 "${REAL_LOG_OUTPUT}")"

assert_contains "a build failure never asks the OS log; no host ever started" \
  "logcalls=0" "$(run_wrapper_with_stub_xcodebuild "${BUILD_FAILURE_OUTPUT}" 65 "${REAL_LOG_OUTPUT}")"

# A retried crash (#1331) runs xcodebuild twice but dies once, and the log is read once, after the
# last attempt. Two dumps of the same window would double the noise for no new evidence.
assert_contains "a retried crash reads the log once, not once per attempt" \
  "logcalls=1" "$(run_wrapper_with_stub_xcodebuild "${CRASHED_OUTPUT}" 65 "${REAL_LOG_OUTPUT}")"

echo
# --- the wiring: every run states the suite's shape (#2193, #2232) -------------------------
#
# suite-stats.test.sh proves the numbers are computed right. These prove the script actually PRINTS
# them, which is a separate claim (L3), and prints them on the runs that matter. The whole reason
# this exists is that a figure nobody regenerates goes stale silently: AGENTS.md carried these by
# hand and both had drifted, one by 768 tests.

SHAPE_ON_PASS="$(run_wrapper_with_stub_xcodebuild "${PASSING_OUTPUT}" 0)"

assert_contains "a passing run states the suite's shape" \
  "Suite shape:" "${SHAPE_ON_PASS}"

# The counts come from THIS run's output, not from anything remembered or written down. 2400 is the
# stub's own figure, so a readout quoting a stored number instead would not produce it.
assert_contains "the shape quotes the run's own totals" \
  "2400 tests in 348 suites" "${SHAPE_ON_PASS}"

assert_contains "and the wall clock the run reported" \
  "19.462s" "${SHAPE_ON_PASS}"

# A red run is exactly when someone wants to know whether the count moved, so the readout must not
# be a reward for passing. A failing run that stays silent about its shape is one where "did this
# even run the whole suite?" cannot be answered from the output.
assert_contains "a failing run states its shape too" \
  "Suite shape:" "$(run_wrapper_with_stub_xcodebuild "${REAL_FAILURE_OUTPUT}" 65 "${REAL_LOG_OUTPUT}")"

# A build failure ran no test at all. It must SAY it could not read the totals rather than print a
# zero, because "0 tests" is a measurement and this run made none (L11).
BUILD_FAILURE_SHAPE="$(run_wrapper_with_stub_xcodebuild "${BUILD_FAILURE_OUTPUT}" 65)"

assert_contains "a run that executed nothing says so instead of reporting zero tests" \
  "could not read the test totals" "${BUILD_FAILURE_SHAPE}"

assert_not_contains "and never claims a zero it did not measure" \
  "0 tests in 0 suites" "${BUILD_FAILURE_SHAPE}"

echo
# --- keep the diagnostic the runner names when it cannot explain a failure (#2321) ----------
#
# When the hosted run dies AND the pure-suite fallback dies with it, the runner has nothing left to
# say about the cause, so it named the file holding the pure suite's whole output and then deleted
# that file on the very next line. The one artifact worth reading was destroyed at the exact moment
# it became the only thing worth reading.
#
# Measured 2026-08-08: three consecutive full runs failed this way. The message sent the
# investigation at the app host, then at an external kill, both wrong. The real cause was recovered
# only by reproducing the run by hand for another 20 minutes, to produce output that had already
# existed twice. The two decisive lines are the ones in the fixture below; nothing in the code was
# involved at all (this Mac's testmanagerd had been up since the previous Tuesday and was wedged).

# Captured from that run's shape. It is a CRASH for the combined scheme (exit 65, "** TEST FAILED **"
# and no named failing test), which is what sends the runner to the pure suite in the first place.
HUNG_RUNNER_OUTPUT='Test Suite '"'"'All tests'"'"' started
2026-08-08 09:12:03.100 xcodebuild[41200:9911] Timed out after 120.0s while initiating control session with daemon.
2026-08-08 09:12:03.200 xctest[41205:9912] [error] CoreData: error: Executing as effective user 501
xctest encountered an error (The test runner hung before establishing connection.)
Failing tests:
** TEST FAILED **'

assert_equals "a hung test runner is a crash, which is what sends the run to the pure suite" \
  "crashed" "$(run_outcome "${HUNG_RUNNER_OUTPUT}" 65)"

# Named first, because a shell assertion whose helper does not exist is the trap this repo keeps
# hitting (L100): the call prints "command not found" to stderr, the substitution comes back empty,
# and every assertion expecting an empty answer below passes on nothing at all.
for HELPER in pure_failure_evidence keep_diagnostic_file; do
  assert_equals "${HELPER} is a function run-tests-locked.sh actually defines" \
    "function" "$(type -t "${HELPER}" 2>/dev/null || echo missing)"
done

HUNG_EVIDENCE="$(pure_failure_evidence "${HUNG_RUNNER_OUTPUT}")"

assert_contains "the line naming the hung runner is kept" \
  "xctest encountered an error (The test runner hung before establishing connection.)" \
  "${HUNG_EVIDENCE}"

assert_contains "and the daemon timeout beside it" \
  "Timed out after 120.0s while initiating control session with daemon." \
  "${HUNG_EVIDENCE}"

# The false positive that makes a bare `error:` grep wrong here, exactly as it does in build_failed:
# every real run of this suite prints CoreData noise carrying "error:", and a filter that keeps it
# buries the two lines that actually name the cause, which is the same defect as printing nothing.
assert_not_contains "CoreData error noise is not offered as a cause" \
  "Executing as effective user 501" "${HUNG_EVIDENCE}"

# What it must PRESERVE, not only what it must catch (L104). A pure suite that genuinely FAILED names
# its failing tests, and those names are the evidence: they were invisible too, since the pure run's
# output goes to the file and never to the screen.
PURE_NAMED_FAILURE_OUTPUT='Test aThingWorks() recorded an issue: Expectation failed
Failing tests:
	OvertureTests.FooTests.aThingWorks()
** TEST FAILED **'
assert_contains "a pure suite that named a failing test has that name printed" \
  "OvertureTests.FooTests.aThingWorks()" "$(pure_failure_evidence "${PURE_NAMED_FAILURE_OUTPUT}")"

# A compile failure in the pure scheme names its own cause too.
assert_contains "a pure suite that did not compile has the compiler error printed" \
  "error: cannot convert value of type" "$(pure_failure_evidence "${BUILD_FAILURE_OUTPUT}")"

# Nothing matching means nothing to print, so the caller can say so plainly instead of printing an
# empty block under a heading promising evidence (L11).
assert_equals "output naming no cause yields no evidence" \
  "" "$(pure_failure_evidence 'Test run with 10 tests in 2 suites passed after 1.0 seconds.')"

# And a run that matches thousands of times is capped, or the useful lines scroll away exactly as
# they would have in the raw file.
MANY_TIMEOUTS="$(for i in $(seq 1 120); do echo "line ${i} Timed out after 120.0s"; done)"
assert_equals "the evidence is capped at the last 20 lines" \
  "20" "$(pure_failure_evidence "${MANY_TIMEOUTS}" | grep -c .)"

assert_contains "the cap keeps the LAST lines, nearest the death" \
  "line 120 Timed out" "$(pure_failure_evidence "${MANY_TIMEOUTS}")"

echo
# The kept file itself: it must survive the run, and the directory holding it must not grow forever.
KEEP_DIR="$(mktemp -d)"
KEEP_SOURCE="$(mktemp)"
printf 'the whole pure-suite log\n' > "${KEEP_SOURCE}"

KEPT_ONE="$(keep_diagnostic_file "${KEEP_SOURCE}" "${KEEP_DIR}" 3)"
assert_equals "the kept file holds the output it was handed" \
  "the whole pure-suite log" "$(cat "${KEPT_ONE}" 2>/dev/null)"

# Bounded, and bounded by DELETING THE OLDEST. Several worktrees run this script on this Mac at once,
# so the directory is shared and every run must leave it at the same fixed size rather than each run
# adding one more file forever.
for i in 1 2 3 4 5; do
  : > "${KEEP_DIR}/pure-suite-20260101-00000${i}.aaaaaa"
done
KEPT_TWO="$(keep_diagnostic_file "${KEEP_SOURCE}" "${KEEP_DIR}" 3)"

assert_equals "the directory is pruned to the number of diagnostics it is allowed to keep" \
  "3" "$(find "${KEEP_DIR}" -name 'pure-suite-*' | grep -c .)"

assert_equals "the diagnostic just kept is one of the survivors" \
  "yes" "$(if [[ -f "${KEPT_TWO}" ]]; then echo yes; else echo "no: ${KEPT_TWO}"; fi)"

assert_equals "and the oldest is the one that went" \
  "no" "$(if [[ -f "${KEEP_DIR}/pure-suite-20260101-000001.aaaaaa" ]]; then echo yes; else echo no; fi)"

assert_equals "while the newest of the old ones stays" \
  "yes" "$(if [[ -f "${KEEP_DIR}/pure-suite-20260101-000005.aaaaaa" ]]; then echo yes; else echo no; fi)"

# Two runs in the same second must not land on one name, or a second worktree's diagnostic silently
# overwrites the first one's at exactly the moment both are worth reading.
assert_equals "two diagnostics kept in the same second are two files, not one" \
  "no" "$(if [[ "${KEPT_ONE}" == "${KEPT_TWO}" ]]; then echo yes; else echo no; fi)"

rm -rf "${KEEP_DIR}" "${KEEP_SOURCE}"

echo
# The wiring, which is the whole claim (L3). Every assertion above passes while main still names a
# file it has already deleted.
#
# The pure suite's output goes to a FILE, never to the screen, so anything asserted against the whole
# run would be satisfied by the combined run's own streamed output carrying the same lines. These
# assert against the section from the pure-suite probe onward, which pre-fix holds one sentence and a
# path.
pure_suite_section() {
  awk '/asking the PURE suite directly/{f=1} f' <<< "$1"
}

PURE_DIAG_DIR="$(mktemp -d)"
PURE_FAIL_RUN="$(run_wrapper_with_stub_xcodebuild "${HUNG_RUNNER_OUTPUT}" 65 "" "${PURE_DIAG_DIR}")"
PURE_SECTION="$(pure_suite_section "${PURE_FAIL_RUN}")"

assert_contains "the pure-suite failure names the cause on screen, not only a path" \
  "The test runner hung before establishing connection." "${PURE_SECTION}"

assert_contains "and the daemon timeout with it" \
  "Timed out after 120.0s while initiating control session with daemon." "${PURE_SECTION}"

# THE case. Whatever path that message points at must still be there when somebody goes to read it.
# Deliberately reads the path back out of the message rather than assuming this fix's own naming, so
# the assertion is about the file existing and not about the string we chose to print.
NAMED_DIAGNOSTIC="$(grep -aoE '/[^[:space:]]+' <<< "${PURE_SECTION}" | tail -1)"
assert_equals "the file the message names still exists when somebody goes to read it" \
  "exists" \
  "$(if [[ -n "${NAMED_DIAGNOSTIC}" && -f "${NAMED_DIAGNOSTIC}" ]]; then echo exists; else echo "missing: ${NAMED_DIAGNOSTIC:-nothing was named}"; fi)"

assert_contains "and it holds the pure suite's whole output, not just the lines printed above" \
  "CoreData: error: Executing as effective user 501" "$(cat "${NAMED_DIAGNOSTIC}" 2>/dev/null)"

# The common path pays nothing. A run with nothing to explain must leave no file behind at all, or a
# shared directory fills up with the output of runs nobody will ever read.
PASS_DIAG_DIR="$(mktemp -d)"
run_wrapper_with_stub_xcodebuild "${PASSING_OUTPUT}" 0 "" "${PASS_DIAG_DIR}" > /dev/null
assert_equals "a passing run keeps no diagnostic at all" \
  "0" "$(find "${PASS_DIAG_DIR}" -type f | grep -c .)"

rm -rf "${PURE_DIAG_DIR}" "${PASS_DIAG_DIR}"

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All run-tests-locked.sh stale-host fixtures passed."
  exit 0
else
  echo "${FAILURES} run-tests-locked.sh stale-host fixture(s) failed."
  exit 1
fi
