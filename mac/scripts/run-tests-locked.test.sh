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

# --- #3392: a run TRUNCATED by a time limit kill is retried once, and the retry names the test -------
#
# This is the other transient cause and by far the commoner one. A test that exceeds its `.timeLimit` is
# killed, xcodebuild relaunches the test process without printing anything about it, and the totals cover
# only what ran afterwards. Measured over twenty-nine full parallel runs on 2026-08-30: roughly one in
# five. Since #3384 and #3389 the truncation is detected from two independent sources and the short-run
# gate refuses the result, so nothing can be read from such a run; what was missing is that somebody had
# to notice and re-run by hand.

# The killed test is itself a NAMED failure, so a truncated run's outcome is almost always "failed". A
# rule that kept "failed" unretryable would therefore never fire at all, which is the thing to get right
# here rather than to assume.
assert_equals "a truncated run is retried even though its outcome is a named failure" \
  "retry" "$(should_retry "failed" 1 2 "RunStateIsPerSlotTests/aCheckStartedWhileAPrepIsLiveIsStillFollowed()")"

# And a truncated run whose remainder PASSED is the dangerous shape: exit 0, a plausible small count, and
# nothing wrong on screen but the short-run gate. It is retried too.
assert_equals "a truncated run whose remainder passed is retried" \
  "retry" "$(should_retry "" 1 2 "Slow/thing()")"

# ONCE, like the crash retry. A test that is killed on every run must not be paid for forever.
assert_equals "a second truncation is not retried" \
  "" "$(should_retry "failed" 2 2 "Slow/thing()")"

# The other direction, or the change would have turned this into a rule that retries every red run (L1).
# Only these two causes are known to be transient; a run short for any other reason is not retried,
# because that would paper over exactly the blindness the short-run gate exists to remove.
assert_equals "an ordinary red with no truncation is still never retried" \
  "" "$(should_retry "failed" 1 2 "")"
assert_equals "a build failure with no truncation is still never retried" \
  "" "$(should_retry "build-failed" 1 2 "")"
assert_equals "and a clean pass is still never retried" \
  "" "$(should_retry "" 1 2 "")"

# The crash retry is untouched, including its own one-retry limit.
assert_equals "a host crash with no truncation is still retried" \
  "retry" "$(should_retry "crashed" 1 2 "")"
assert_equals "and still only once" \
  "" "$(should_retry "crashed" 2 2 "")"

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
#
# #2323: the fifth and sixth are the machine's test service as this run should find it, its PID and
# its `ps -o etime=` age. Both default to absent, which is a Mac with no testmanagerd running, so
# every call above this one is unchanged. They exist because the advisory reads a REAL daemon on a
# real Mac, and a fixture that reached the live process table would assert about whatever this Mac
# happened to be doing (L2), including the healthy two-day-old daemon measured here on 2026-08-16.
run_wrapper_with_stub_xcodebuild() {
  local xcodebuild_output="$1" xcodebuild_exit="$2" log_output="${3:-}" diagnostics_dir="${4:-}"
  local daemon_pid="${5:-}" daemon_etime="${6:-}" starting_baseline="${7:-}"
  local bin_dir output code log_calls baseline hosted_record

  bin_dir="$(fixture_scratch_dir)"
  [[ -n "${diagnostics_dir}" ]] || diagnostics_dir="${bin_dir}/diagnostics"

  # flock's real job is serialising xcodebuild across worktrees, which is irrelevant here; once it
  # holds the lock it execs the rest of its arguments, and so does this.
  cat > "${bin_dir}/flock" <<'STUB'
#!/usr/bin/env bash
shift
exec "$@"
STUB

  # A process table with nothing Overture-shaped in it, so the pre-flight neither kills anything nor
  # stops for a blocking Debug app. The etime branch answers the ONE other question main asks `ps`
  # (#2323: how old the machine's test service is) and is deliberately told apart by the flag rather
  # than by answering both questions with one string, which would feed the age parser a process line.
  cat > "${bin_dir}/ps" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *etime*) echo "${daemon_etime}"; exit 0 ;;
esac
echo "  501 /sbin/launchd"
STUB

  # A Mac with no test service running, unless this call says otherwise. Nothing printed and a
  # nonzero status is what the real pgrep does when it matches nothing, which is the case the
  # advisory must stay silent on.
  #
  # It intercepts ONLY its own question and hands every other one to the real pgrep. The stall
  # watcher tears itself down with `pgrep -P <pid>` to find its children, and a stub that answered
  # that with a fixed PID made the run try to kill a process it had never started: the first version
  # of this one aimed a `kill` at the very testmanagerd PID the fixture was pretending to observe.
  cat > "${bin_dir}/pgrep" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *testmanagerd*)
    [[ -n "${daemon_pid}" ]] || exit 1
    echo "${daemon_pid}"
    exit 0
    ;;
esac
exec /usr/bin/pgrep "\$@"
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

  chmod +x "${bin_dir}/flock" "${bin_dir}/ps" "${bin_dir}/pgrep" "${bin_dir}/xcodebuild" "${bin_dir}/log"

  # #2195: a throwaway baseline. The stub reports a handful of tests, so against the real one every
  # wrapper run here would read as a catastrophically short run, and a fixture must never write to the
  # file the real gate is measured against either (L2).
  local baseline_file="${bin_dir}/baseline"
  # #3233: the screens record, into the throwaway bin dir rather than the repository's own file.
  # Defaulted HERE rather than exported around one block, so every call in this fixture is
  # structurally unable to write it (L2). It matters now in a way it did not before: until this
  # change no stub output named a hosted suite as passed, and the log below names two, so without
  # this the fixture would stamp the live record with a day on which nothing rendered a view.
  HOSTED_RECORD_AFTER_PARALLEL="${bin_dir}/hosted-seen"
  hosted_record=""
  # #3233: the count this Mac would already be holding, when the assertion is about the SHORT RUN
  # gate itself. Absent by default, which is a Mac that has never had a green full run and so makes
  # no claim about any of these, leaving every call above this one unchanged.
  [[ -z "${starting_baseline}" ]] || echo "${starting_baseline}" > "${baseline_file}"
  # #3166: the run-duration series, into the throwaway bin dir. Defaulted HERE rather than exported
  # around one block, so every call in this fixture is structurally unable to write the repository's own
  # (L2). It is not hypothetical: without it, nine stubbed runs of the wrapper appended their fake sizes
  # to the live series on the first full run after the series shipped, and its advisory then reported the
  # real suite as "SLOWER than twice the median of the last 18 full runs (19s)". Found by reading the
  # file after a run, exactly as the same defect was found for the live-store corpus record.
  SUITE_SERIES_AFTER_RUN="${bin_dir}/suite-run-series"
  output="$(PATH="${bin_dir}:${PATH}" OVERTURE_TEST_BASELINE_FILE="${baseline_file}" \
    OVERTURE_TEST_DIAGNOSTICS_DIR="${diagnostics_dir}" \
    OVERTURE_HOSTED_SUITE_RECORD="${HOSTED_RECORD_AFTER_PARALLEL}" \
    OVERTURE_SUITE_RUN_SERIES="${SUITE_SERIES_AFTER_RUN}" \
    "${SCRIPT_DIR}/run-tests-locked.sh" 2>&1)"
  code=$?
  log_calls="$(grep -c . "${bin_dir}/log-calls" 2>/dev/null || echo 0)"
  # #2821: what this run RECORDED as the count every later run is measured against. Read out here
  # because the file is thrown away with the bin dir, and because "did this run move the baseline?"
  # is not answerable from anything the script prints.
  baseline="$(cat "${baseline_file}" 2>/dev/null || true)"
  # Read out here, because "did this run stamp the screens?" is not answerable from anything the
  # script prints and the file goes with the directory below.
  hosted_record="$(cat "${HOSTED_RECORD_AFTER_PARALLEL}" 2>/dev/null || true)"
  # #3166: how many readings this run appended to its OWN series. Read out here for the same reason the
  # two above are: the file goes with the directory below, and "did this run record its duration?" is not
  # answerable from anything the script prints. A count rather than the text, because the date and the
  # duration are this machine's and would make the assertion about the day it ran.
  local series_lines
  series_lines="$(grep -c '^20' "${SUITE_SERIES_AFTER_RUN}" 2>/dev/null || echo 0)"
  rm -rf "${bin_dir}"
  printf '%s\nbaseline=%s\nscreensrecord=%s\nseriesrecord=%s\nlogcalls=%s\nexit=%s\n' \
    "${output}" "${baseline}" "${hosted_record}" "${series_lines}" "${log_calls}" "${code}"
}

# #3233: the repository's OWN screens record, and what is in it BEFORE any stub run below.
#
# It matters from this change onward in a way it did not before: until now no stub output named a
# hosted suite as PASSED, so no fixture run could stamp it. The parallel fixture log names two, and a
# run of this file must never be able to record that Dan's screens were verified on a day when nothing
# rendered a view (L2). The override in the helper is what makes that structural; this is the check
# that the override is really in force, in the same before-against-after shape the live store record
# uses, so it holds on a pristine checkout and on a machine that has been running the suite for months.
REPO_HOSTED_RECORD="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/.overture-hosted-suite-seen"
repo_hosted_record_state() {
  if [[ -e "${REPO_HOSTED_RECORD}" ]]; then
    shasum -a 256 "${REPO_HOSTED_RECORD}" | cut -d' ' -f1
  else
    echo absent
  fi
}
REPO_HOSTED_RECORD_BEFORE="$(repo_hosted_record_state)"

# #3166: the same, for the run-duration series. Same shape and the same reason, and it is not
# hypothetical here either: the series shipped without this fixture overriding it, and the nine stubbed
# wrapper runs below appended their fake sizes to the live file on the very first full run afterwards.
# The advisory then reported the real suite as slower than twice the median of "the last 18 full runs",
# where the median was 19 seconds, because seventeen of those runs were this fixture's stubs.
REPO_SUITE_SERIES="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/.overture-suite-run-series"

# Judged by CONTENT SIGNATURE rather than by a hash taken before and after, and the difference is not
# fussiness. `scripts/test-all.sh` runs the REAL suite in one lane while this fixture runs in the other,
# and a real run legitimately appends to this file, so a before-against-after hash is racing the run in
# the next lane: it went red on exactly that, reporting the real suite's own reading as this fixture's
# pollution. What is actually forbidden is this fixture's FAKE sizes appearing there, and the stub logs
# below are the only place those numbers come from.
repo_suite_series_holds_a_stub_reading() {
  [[ -e "${REPO_SUITE_SERIES}" ]] || { echo no; return 0; }
  local count
  count="$(awk '$2 == 1574 || $2 == 2400 || $2 == 12 || $2 == 26 { n++ } END { print n + 0 }' \
    "${REPO_SUITE_SERIES}" 2>/dev/null || echo 0)"
  [[ "${count}" -gt 0 ]] && echo yes || echo no
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

# --- the wiring: every run says whether the LIVE store invariants measured anything (#2991) ------
#
# suite-stats.test.sh proves the four readings are right. These prove the wrapper PRINTS one, which
# is a separate claim (L3). The corpus line has been printed by the suite itself since #2986, and
# nobody was scheduled to read it: measured 2026-08-19 both invariants sat at zero rows and passed.

assert_contains "a passing run says where the live store invariants stand" \
  "Live store invariants:" "${SHAPE_ON_PASS}"

# The stub's run carries no corpus line at all, which is the state that must never read as clean: it
# is what a scoped run produces, and an absent measurement is not a good one (L98).
assert_contains "a run with no corpus line says it is unmeasured rather than saying nothing" \
  "NOT REPORTED" "${SHAPE_ON_PASS}"

# EVERY run below writes its record into a throwaway path, never the repository. Without this the
# "measuring" case wrote into the real repo root, recording that both invariants had measured rows on
# a day the live store held none. A test must be structurally unable to touch the live tree (L2).
CORPUS_RECORD_DIR="$(fixture_scratch_dir)"
export OVERTURE_LIVE_CORPUS_RECORD="${CORPUS_RECORD_DIR}/seen"

# #3172: the repo-root default, and what is there BEFORE any stub below runs.
#
# The claim this fixture makes about it is that the stub runs leave it alone. That was written as
# "the file is absent", which is a different claim and one that stops being true the first time this
# machine runs a real suite whose live store invariants measure anything: that run writes this exact
# path, by design, and the assertion then fails forever. Both halves happened here in one session on
# 2026-08-27, one `scripts/test-all.sh` run writing `reached=2026-08-27` and the next reporting
# `FAILED - scripts/run-shell-fixtures.sh` with the Swift suite fully green.
#
# So it compares BEFORE against AFTER, which is the claim, and is true on a pristine checkout and on a
# machine that has been running the suite for months alike (L68). Same shape as
# scripts/check-tree-untouched.sh, for the same reason: nobody runs a suite on a clean tree.
REPO_CORPUS_RECORD="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/.overture-live-corpus-seen"
repo_corpus_record_state() {
  if [[ -e "${REPO_CORPUS_RECORD}" ]]; then
    shasum -a 256 "${REPO_CORPUS_RECORD}" | cut -d' ' -f1
  else
    echo absent
  fi
}
REPO_CORPUS_RECORD_BEFORE="$(repo_corpus_record_state)"

# And a run that DOES carry one, with both counts at zero, is called dormant on screen. Without this
# the wiring would be proved only against the absent case, which is the easy half.
DORMANT_RUN="$(run_wrapper_with_stub_xcodebuild "LIVE STORE CORPUS: 936 shows, 4 replied rows, 0 with a reply still open, 0 whose writer a contact holds, 0 reached-out rows in play.
${PASSING_OUTPUT}" 0)"

# The refusal that carries the whole duration: a run in which nothing measured writes NOTHING. If it
# stamped today regardless, the recorded date would move every run, the duration would always read
# zero, and the dormancy would be invisible behind a date that looks like a measurement.
assert_equals "a dormant run writes no record at all" \
  "absent" "$([[ -e "${OVERTURE_LIVE_CORPUS_RECORD}" ]] && echo present || echo absent)"
assert_contains "a run whose invariants measured nothing says DORMANT" \
  "Live store invariants: DORMANT" "${DORMANT_RUN}"
assert_not_contains "and that run is not also called unmeasured" \
  "Live store invariants: NOT REPORTED" "${DORMANT_RUN}"

# #2991's second half: the DURATION reaches the screen, not just the state. The stub run writes its
# record into a throwaway HOME-adjacent path via the wrapper's own repo root, so this asserts the
# shape of the sentence rather than a specific date, which moves with the clock (L130).
assert_contains "a dormant run says how long, not only that it is dormant" \
  "has measured nothing" "${DORMANT_RUN}"

# The positive control, in the same fixture: rows present reads as measuring, so the two states are
# genuinely told apart rather than every run reporting the same thing (L159).
MEASURING_RUN="$(run_wrapper_with_stub_xcodebuild "LIVE STORE CORPUS: 936 shows, 4 replied rows, 3 with a reply still open, 3 whose writer a contact holds, 5 reached-out rows in play.
${PASSING_OUTPUT}" 0)"
assert_contains "a run whose invariants had rows says so, with the counts" \
  "measuring, over 3 rows the writer-resolution rule can judge and 5 reached-out rows in play" "${MEASURING_RUN}"
assert_not_contains "and is not called dormant" \
  "DORMANT" "${MEASURING_RUN}"

# The positive half of the same rule: a run that DID measure writes the record, so the refusal above is
# a refusal rather than a writer that never works at all (L159).
assert_equals "a measuring run does write the record" \
  "present" "$([[ -e "${OVERTURE_LIVE_CORPUS_RECORD}" ]] && echo present || echo absent)"
# #3165: the key is `writer=`, not `open=`. The readout is measured by the rows the
# writer-resolution rule can judge, because the still-open count empties whenever Dan is up to date, and
# a key named `open` counting something else is how one word comes to name two units (L118).
assert_contains "and the record names both invariants it measured" \
  "writer=" "$(cat "${OVERTURE_LIVE_CORPUS_RECORD}" 2>/dev/null)"
assert_contains "and the reached-out one too" \
  "reached=" "$(cat "${OVERTURE_LIVE_CORPUS_RECORD}" 2>/dev/null)"

# Nothing the stub runs did reached the repository itself, which is what went wrong the first time.
# Judged by CONTENT against what was there before them, so a real record this machine already carries
# is not mistaken for something these runs wrote (#3172).
assert_equals "no run above changed the record in the repository" \
  "${REPO_CORPUS_RECORD_BEFORE}" "$(repo_corpus_record_state)"

rm -rf "${CORPUS_RECORD_DIR}"
unset OVERTURE_LIVE_CORPUS_RECORD

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

# #2322: this output is no longer read as a crashed HOST. It is the machine's test service wedged,
# which is a different cause with a different fix, and the assertion that used to stand here (that
# it is "crashed") is what sent three consecutive runs into a retry that rebuilt everything and
# named the blameless app host. The wedged section at the end of this file owns it now.
assert_equals "a hung test runner is the machine's test service, not a crashed host" \
  "test-service-wedged" "$(run_outcome "${HUNG_RUNNER_OUTPUT}" 65)"

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
KEEP_DIR="$(fixture_scratch_dir)"
KEEP_SOURCE="$(fixture_scratch_file)"
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

# The run driven here is a host that DIED, not the wedged test service above: since #2322 a wedged
# service never reaches the pure-suite probe at all, because the pure scheme goes through the same
# daemon and a probe would meet the same wedge after paying for another full build.
#
# Assembled from lines this repo has captured elsewhere rather than taken from one recorded run, and
# said so rather than presented as a capture (L48): the launch failure is NEVER_LAUNCHED_OUTPUT's,
# and `encountered an error` is xctest's own prefix, already the shape pure_failure_evidence reads.
HOST_DIED_OUTPUT='Test Suite '"'"'All tests'"'"' started
2026-08-08 09:12:03.200 Overture[41205:9912] [error] CoreData: error: Executing as effective user 501
xctest encountered an error (Early unexpected exit, operation never finished bootstrapping)
	Could not launch "OvertureTests"
Failing tests:
** TEST FAILED **'

assert_equals "a host that died is still a crash, and still probes the pure suite" \
  "crashed" "$(run_outcome "${HOST_DIED_OUTPUT}" 65)"

PURE_DIAG_DIR="$(fixture_scratch_dir)"
PURE_FAIL_RUN="$(run_wrapper_with_stub_xcodebuild "${HOST_DIED_OUTPUT}" 65 "" "${PURE_DIAG_DIR}")"
PURE_SECTION="$(pure_suite_section "${PURE_FAIL_RUN}")"

assert_contains "the pure-suite failure names the cause on screen, not only a path" \
  "Early unexpected exit, operation never finished bootstrapping" "${PURE_SECTION}"

assert_contains "and the launch failure with it" \
  "Could not launch" "${PURE_SECTION}"

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
PASS_DIAG_DIR="$(fixture_scratch_dir)"
run_wrapper_with_stub_xcodebuild "${PASSING_OUTPUT}" 0 "" "${PASS_DIAG_DIR}" > /dev/null
assert_equals "a passing run keeps no diagnostic at all" \
  "0" "$(find "${PASS_DIAG_DIR}" -type f | grep -c .)"

rm -rf "${PURE_DIAG_DIR}" "${PASS_DIAG_DIR}"

echo
# --- the failing test list, reprinted at the end (#2600) -----------------------------------
#
# suite-stats.test.sh proves the list is PARSED right. These prove the script prints it, on the runs
# that have one, and prints it LAST, which is the whole of what the issue asks for: the honest
# answer already existed roughly forty thousand lines up a log nobody reads to the end.

# A run whose failures are ALL Issue.record, so the cheap partial reading of the log ("grep for
# Expectation failed:") finds nothing at all while two tests really failed. That is the 2026-08-12
# defect in its smallest form.
ISSUE_RECORD_ONLY_OUTPUT="Test aGuardHolds() recorded an issue at Bar.swift:44:3: the venue guard did not fire
Test anotherGuardHolds() recorded an issue at Baz.swift:9:1: the pill count did not match its rows
Failing tests:
	OvertureTests.BarTests.aGuardHolds()
	OvertureTests.BazTests.anotherGuardHolds()

** TEST FAILED **"

REPRINT_RUN="$(run_wrapper_with_stub_xcodebuild "${ISSUE_RECORD_ONLY_OUTPUT}" 65)"

assert_contains "a failed run reprints the list with the count xcodebuild itself named" \
  "FAILING TESTS (2)" "${REPRINT_RUN}"

assert_contains "and names each failing test" \
  "OvertureTests.BazTests.anotherGuardHolds()" "${REPRINT_RUN}"

# The last line of a fixture in this file is always the wrapper's own exit= line, so ordering is
# asserted against the one thing it has to beat: the shape readout it sits beside.
line_number_of() {
  local haystack="$1" needle="$2"
  grep -n -F -- "${needle}" <<< "${haystack}" | tail -1 | cut -d: -f1
}

assert_equals "the reprint comes after the shape line, so the list is the last thing on screen" \
  "after" \
  "$(if [[ "$(line_number_of "${REPRINT_RUN}" "FAILING TESTS")" -gt "$(line_number_of "${REPRINT_RUN}" "Suite shape:")" ]]; then echo after; else echo before; fi)"

assert_not_contains "a passing run has no list to reprint" \
  "FAILING TEST" "${PASSING_RUN}"

# A crash prints the heading with nothing under it (#1006's whole tell), and must never come back as
# "FAILING TESTS (0)": a run that named no failing test did not fail, it died, and the crash path
# already says so in its own words.
assert_not_contains "a crashed run does not reprint an empty list as a count of zero" \
  "FAILING TEST" "${CRASH_RUN}"

echo
# --- a post-restart remainder is not the run (#2821) ---------------------------------------
#
# Measured 2026-08-16 while re-checking #2808's mutations: a test that exceeded its one minute
# .timeLimit killed the test process, xcodebuild restarted and ran the remainder, and the final line
# read "Suite shape: 12 tests in 2 suites, 0.009s" for a run that had really started 70 tests across
# 8 suites.
#
# The green fixture is deliberate rather than a capture, and it is the case that matters: a restarted
# run that ends red is already caught by the SHORT RUN gate whenever a baseline exists, while a
# restarted run that ends GREEN is the one that would quietly RECORD its remainder as the count every
# later run is measured against, disabling that gate for everything after it.
RESTARTED_GREEN_OUTPUT="Test Suite 'All tests' started
Restarting after unexpected exit, crash, or test timeout in OvertureTests.PrepTests/aSlowCheck(); summary will include totals from previous launches.
Test run with 12 tests in 2 suites passed after 0.009 seconds.
** TEST SUCCEEDED **"

RESTARTED_RUN="$(run_wrapper_with_stub_xcodebuild "${RESTARTED_GREEN_OUTPUT}" 0)"

assert_contains "a restarted run refuses to state a shape and names the restart" \
  "Suite shape: NOT REPORTED" "${RESTARTED_RUN}"

# THE misreading. AGENTS.md names that line as the reference for "did this run execute the whole
# suite?", so a plausible small number printed for a run that was broken rather than small is the
# one answer it must never give.
#
# Scoped to what this SCRIPT says, not to the whole run: xcodebuild's own streamed output carries
# that sentence too, by construction, and an assertion over everything on screen would be answered
# by the raw log rather than by the readout under test (L135).
assert_not_contains "and never presents the remainder's count as the run's own" \
  "12 tests in 2 suites" "$(grep 'run-tests-locked.sh:' <<< "${RESTARTED_RUN}")"

assert_equals "a restarted run never becomes the baseline later runs are measured against" \
  "baseline=" "$(grep '^baseline=' <<< "${RESTARTED_RUN}")"

# The other half of the same claim: this must not have disabled the baseline for ordinary runs, or
# the SHORT RUN gate quietly stops having anything to measure against.
assert_equals "an ordinary green run still records its own count as the baseline" \
  "baseline=2400" "$(grep '^baseline=' <<< "${PASSING_RUN}")"

echo
# --- a wedged test service is not a crashed host (#2322) -----------------------------------
#
# Measured 2026-08-08: three consecutive runs reported "the test host crashed with no named test
# failure (a known self-hosted flake)" and retried. The real cause was this Mac's testmanagerd
# wedged since the previous Tuesday, so xctest hung before establishing a connection and ZERO tests
# executed. The message named the app host, which was blameless, the retry cost a second full build
# each time, and the investigation went down two wrong paths before the raw error was read.
#
# The runner already held the evidence that separates them: a crash has a partial test count, this
# has none at all, and the output carries the daemon's own wording rather than a crash signature.

assert_equals "a wedged test service is never retried; a second build meets the same wedge" \
  "" "$(should_retry "test-service-wedged" 1 2)"

# Nor probed. The pure scheme is a different scheme through the SAME daemon, so the probe would hang
# identically after paying for another full build, and the runner now names the cause itself rather
# than needing the probe's output to do it.
assert_equals "a wedged test service is never probed; the pure suite uses the same daemon" \
  "" "$(should_probe_pure_suite "test-service-wedged")"

# What it must PRESERVE, not only what it must catch (L104). The markers alone are not enough: a
# daemon timeout can also appear in a run that DID execute tests and then lost its host, and that is
# an ordinary crash with an ordinary retry. Zero tests executed is the other half of the tell.
HUNG_MIDRUN_OUTPUT='Test Suite '"'"'All tests'"'"' started
Test run with 1574 tests in 229 suites passed after 10.851 seconds.
2026-08-08 09:12:03.100 xcodebuild[41200:9911] Timed out after 120.0s while initiating control session with daemon.
Failing tests:
** TEST FAILED **'
assert_equals "a run that executed tests and then lost the daemon is still an ordinary crash" \
  "crashed" "$(run_outcome "${HUNG_MIDRUN_OUTPUT}" 65)"

assert_equals "and an ordinary dead host with no daemon markers is untouched" \
  "crashed" "$(run_outcome "${CRASHED_OUTPUT}" 65)"

assert_equals "a genuine test failure is still a failure, wedge markers or not" \
  "failed" "$(run_outcome "${REAL_FAILURE_OUTPUT}" 65)"

WEDGED_RUN="$(run_wrapper_with_stub_xcodebuild "${HUNG_RUNNER_OUTPUT}" 65 "${REAL_LOG_OUTPUT}")"

assert_contains "a wedged run names the machine's test service" \
  "testmanagerd" "${WEDGED_RUN}"

assert_contains "and says no test ran at all" \
  "NO TEST RAN" "${WEDGED_RUN}"

assert_contains "and hands over the one command that fixes it" \
  "pkill -x testmanagerd" "${WEDGED_RUN}"

# THE regression. Every one of these is what the 2026-08-08 runs did instead.
assert_not_contains "a wedged run never blames the app host" \
  "the test host crashed" "${WEDGED_RUN}"

assert_not_contains "nor reports the run as having died" \
  "the test run CRASHED" "${WEDGED_RUN}"

assert_not_contains "and is never retried" \
  "Retrying once" "${WEDGED_RUN}"

# No host ever launched, so there is no host log to read and nothing in it to find. Asserted on the
# call count rather than on the output, because "asked and found nothing" prints the same as "never
# asked" (L11).
assert_contains "a wedged run never asks the OS log about a host that never started" \
  "logcalls=0" "${WEDGED_RUN}"

assert_equals "a wedged run exits with xcodebuild's own code" \
  "exit=65" "$(tail -n 1 <<< "${WEDGED_RUN}")"

echo
# --- say when the machine's test service is old enough to be the problem (#2323) -----------
#
# The daemon's age was one cheap read and it was the whole answer on 2026-08-08, and nothing pointed
# at it. Advisory only and never blocking, matching prune-stale-registrations.sh: a long-lived daemon
# is usually fine, and the line only has to be in front of somebody at the moment a run fails oddly.

# `ps -o etime=` writes days only when there are days, so the shapes below are the three it produces.
assert_equals "an age in minutes and seconds is not old enough to mention" \
  "" "$(testmanagerd_age_report "1234" "07:41" 5)"

assert_equals "nor is one in hours" \
  "" "$(testmanagerd_age_report "1234" "23:07:41" 5)"

# Calibrated against a real reading rather than a round number: this Mac's testmanagerd was
# 2 days 8 hours old and perfectly healthy on 2026-08-16, so a threshold below that would fire on
# the ordinary case and be ignored within a day (L93, L147).
assert_equals "and neither is the two-day-old daemon measured here while healthy" \
  "" "$(testmanagerd_age_report "1234" "02-08:15:57" 5)"

SIX_DAY_REPORT="$(testmanagerd_age_report "1234" "06-03:14:05" 5)"

assert_contains "a daemon days past the threshold is named, with its age and PID" \
  "6 days" "${SIX_DAY_REPORT}"

assert_contains "and the PID, so it can be looked at before it is killed" \
  "1234" "${SIX_DAY_REPORT}"

assert_contains "and the one command that clears it" \
  "pkill -x testmanagerd" "${SIX_DAY_REPORT}"

# A reading it cannot parse is not an age. Saying nothing is right here (this is advisory), but
# saying nothing must never be reached by scoring an unreadable value as young (L50).
assert_equals "an unreadable age is not scored as a young daemon" \
  "" "$(testmanagerd_age_report "1234" "not an elapsed time" 5)"

assert_equals "and no daemon at all says nothing" \
  "" "$(testmanagerd_age_report "" "" 5)"

# The wiring, which is the separate claim (L3). The advisory is read BEFORE the lock, so a run
# queued behind another worktree's suite still carries it.
OLD_DAEMON_RUN="$(run_wrapper_with_stub_xcodebuild "${PASSING_OUTPUT}" 0 "" "" "24298" "06-03:14:05")"

assert_contains "a run on a Mac whose test service is days old says so" \
  "testmanagerd" "${OLD_DAEMON_RUN}"

assert_equals "and it is still only advisory: the run passes" \
  "exit=0" "$(tail -n 1 <<< "${OLD_DAEMON_RUN}")"

YOUNG_DAEMON_RUN="$(run_wrapper_with_stub_xcodebuild "${PASSING_OUTPUT}" 0 "" "" "24298" "03:14:05")"

assert_not_contains "an ordinary run on a fresh daemon says nothing about it" \
  "testmanagerd" "${YOUNG_DAEMON_RUN}"

assert_not_contains "and neither does a run on a Mac with no test service running at all" \
  "testmanagerd" "${PASSING_RUN}"

echo
# --- a parallel run is counted, and a short one is refused (#3233) --------------------------
#
# THE incident, 2026-08-29. The suite was run once with `-parallel-testing-enabled YES` for the speed
# audit behind milestone 60. xcodebuild stopped printing its "Test run with N tests" summary and
# reported every test on its own line instead, nothing here could read that format, and so:
#
#   * the run ended with "Suite shape: could not read the test totals from this run";
#   * the executed count was EMPTY, so the SHORT RUN gate had nothing to compare and could not fire;
#   * 4,875 of 8,595 tests had actually run, one of the two workers printing 58 lines before its
#     entire share vanished with no crash line anywhere;
#   * and the only thing on screen was a list of 12 failing tests, offered as the whole story.
#
# A run missing 3,720 tests presented as an ordinary red is exactly the reading #2195 built this gate
# to prevent, and the gate was intact the whole time. It was blind, not broken (L98, L11).
#
# Driven through the REAL script against that run's own output, trimmed, because the unit tests over
# the parser cannot show that the gate downstream of it now fires.
PARALLEL_RUN_LOG="$(cat "${SCRIPT_DIR}/lib/fixtures/parallel-run-20260829.log")"
PARALLEL_RUN="$(run_wrapper_with_stub_xcodebuild "${PARALLEL_RUN_LOG}" 65 "" "" "" "" 8595)"

assert_contains "a parallel run short of the baseline is refused as a SHORT RUN" \
  "SHORT RUN" "${PARALLEL_RUN}"

# Both numbers, because the point of the message is that the reader can see the size of what is
# missing without going and finding the baseline themselves.
assert_contains "and the refusal names what ran" \
  "this run executed 26 tests" "${PARALLEL_RUN}"

assert_contains "and what was expected of it" \
  "the 8595 the last green run on this Mac ran" "${PARALLEL_RUN}"

# This one was already red, so it keeps xcodebuild's own code rather than being flattened to 1.
assert_equals "a short red run keeps xcodebuild's own exit code" \
  "exit=65" "$(tail -n 1 <<< "${PARALLEL_RUN}")"

# THE consequence, and the case worth building by hand rather than capturing. A short run that ends
# RED is caught by its own failures whatever this gate does; a short run that prints the SUCCESS
# banner is the one #1006 saw ("Test run with 1574 tests ... passed" over a ~2400 test suite), and
# under this format it is entirely possible: the missing worker printed no failure and no crash line,
# so had the twelve failures been in ITS share the same run would have come back green and short.
# A result that cannot be believed must never exit 0, or test-all.sh goes on to say the suite passed.
PARALLEL_SHORT_GREEN="$(awk '/^Failing tests:/{exit} {print}' <<< "${PARALLEL_RUN_LOG}")
** TEST SUCCEEDED **"
PARALLEL_GREEN_RUN="$(run_wrapper_with_stub_xcodebuild "${PARALLEL_SHORT_GREEN}" 0 "" "" "" "" 8595)"

assert_contains "a short parallel run that reports SUCCESS is still refused" \
  "SHORT RUN" "${PARALLEL_GREEN_RUN}"

assert_equals "and cannot exit 0 on the strength of its own banner" \
  "exit=1" "$(tail -n 1 <<< "${PARALLEL_GREEN_RUN}")"

assert_equals "nor record its own short count as the baseline" \
  "baseline=8595" "$(grep '^baseline=' <<< "${PARALLEL_GREEN_RUN}")"

# And it is refused for the RIGHT reason. Before the parser could read this format the count came
# back empty, which made a green run of 26 tests indistinguishable from a scope that matched nothing:
# the run was still stopped, by NOTHING RAN, and the remedy it hands over is "check the -only-testing:
# path you passed", which changes nothing about the state this reader is actually in (L111, L11).
assert_not_contains "and never as a scope that matched nothing, which it was not" \
  "NOTHING RAN" "${PARALLEL_GREEN_RUN}"

# And it must not be read as one of the other two things that also arrive with no usable count. A
# scope that matched nothing and a run that started and died partway want different responses, and
# this run started plenty.
assert_not_contains "a short parallel run is not reported as NOTHING RAN" \
  "NOTHING RAN" "${PARALLEL_RUN}"

# The readout, which is what AGENTS.md names as the reference for "did this run execute the whole
# suite?". Before this it said it could not tell.
assert_contains "the shape readout states a parallel run's counts" \
  "Suite shape: 26 tests in 12 suites" "${PARALLEL_RUN}"

# The duration is the run's own elapsed reading, never the sum of the per-test seconds, which in this
# trimmed log come to 338.423s for a run that took 95.447. Scoped to what this SCRIPT prints: the raw
# log carries those per-test numbers by construction (L135).
assert_contains "and its wall clock, not the sum of its per-test seconds" \
  "95.447s" "$(grep 'run-tests-locked.sh: Suite shape' <<< "${PARALLEL_RUN}")"

# The baseline is untouched. A truncated run recording its own count would lower the bar every later
# run is measured against, which is the failure mode that disables the gate permanently.
assert_equals "a short parallel run never becomes the new baseline" \
  "baseline=8595" "$(grep '^baseline=' <<< "${PARALLEL_RUN}")"

# The other side of the same rule, so this is not passing because the gate refuses everything: the
# identical log against a baseline that run is NOT short of is an ordinary red, named by its failures.
PARALLEL_RUN_IN_FULL="$(run_wrapper_with_stub_xcodebuild "${PARALLEL_RUN_LOG}" 65 "" "" "" "" 26)"

assert_not_contains "a parallel run that is NOT short is not accused of being one" \
  "SHORT RUN" "${PARALLEL_RUN_IN_FULL}"

assert_contains "and is reported by its failing tests, as any red run is" \
  "FAILING TESTS (12)" "${PARALLEL_RUN_IN_FULL}"

# The SCREENS readout, which is the same defect as the count one wearing different clothes. A parallel
# run prints no `Suite "..." passed` line anywhere, so the #1995 reader found nothing and every such run
# said the screens went unverified, including the runs that had just rendered all 49 hosted suites. This
# log names two of them as passed on the app host's own destination.
assert_contains "a parallel run that rendered a hosted suite says the screens were verified" \
  "verified by this run" "$(grep 'Screen tests' <<< "${PARALLEL_RUN}")"

# And it RECORDS it, into the throwaway path this fixture is given rather than the repository's own.
# Without that record the reader above is a claim nothing acts on (L3), and without the throwaway path
# these very runs would stamp the live tree with a day on which no view was rendered at all (L2).
assert_equals "and records that against the run's own throwaway file, never the repository's" \
  "screensrecord=screens=$(date +%Y-%m-%d)" "$(grep '^screensrecord=' <<< "${PARALLEL_RUN}")"

# Nothing above reached the repository's own copy. Judged by CONTENT against what was there before,
# so a real record this machine already carries is not mistaken for something these runs wrote
# (#3172's reason, and its shape).
assert_equals "and no run in this fixture changed the repository's screens record" \
  "${REPO_HOSTED_RECORD_BEFORE}" "$(repo_hosted_record_state)"

# #3166: nor its run-duration series. None of this fixture's fake sizes may appear there.
assert_equals "and no run in this fixture wrote its fake sizes into the repository's series" \
  "no" "$(repo_suite_series_holds_a_stub_reading)"

# And a run really did write its OWN series, or the assertion above would pass by nothing being written
# anywhere and the override would be untested (L3, L98).
assert_equals "while a full run writes one reading into its own series" \
  "seriesrecord=1" "$(grep '^seriesrecord=' <<< "${PARALLEL_RUN}")"

# ---------------------------------------------------------------------------
# #2577: the stall-versus-queue scenarios live in run-tests-locked-stall.test.sh
# ---------------------------------------------------------------------------
# Moved to their own fixture file (#2601), because they spend real wall-clock seconds by design (the
# silences under test are silences in time) and the fixtures run concurrently, so in their own file
# that waiting happens beside this file's work instead of after it.


# --- only a test scope switches the short-run gate off (#3234) -----------------------------------
#
# The gate compares what a run executed against the last green full run and refuses a materially short
# one. It has to stand down for a deliberately scoped run, which legitimately executes a handful of
# tests, and it used to do that for ANY argument at all.
#
# That is how #3234's parallel experiment came to be measured with no gate on it. Measured 2026-08-30:
# a parallel run executed 5,217 tests against a baseline of 8,618, lost its second worker's entire share
# with no crash line anywhere, and printed an ordinary verdict, because `-parallel-testing-enabled YES`
# had marked the run scoped. A gate that switches itself off exactly where it is needed is the shape
# this repo keeps writing down (L98, L259).
assert_equals "a run with no arguments is not scoped" "not scoped" \
  "$(run_is_scoped && echo scoped || echo "not scoped")"
assert_equals "the parallel flags do NOT scope a run, which is the whole of #3234's blind spot" \
  "not scoped" \
  "$(run_is_scoped -parallel-testing-enabled YES -parallel-testing-worker-count 12 && echo scoped || echo "not scoped")"
assert_equals "nor does a destination or a result bundle" "not scoped" \
  "$(run_is_scoped -destination 'platform=macOS' -resultBundlePath /tmp/x && echo scoped || echo "not scoped")"
assert_equals "a -only-testing: argument DOES scope it" "scoped" \
  "$(run_is_scoped -only-testing:OvertureTests/SomeSuite && echo scoped || echo "not scoped")"
assert_equals "and it is found wherever it sits in the arguments" "scoped" \
  "$(run_is_scoped -parallel-testing-enabled YES -only-testing:OvertureTests/SomeSuite && echo scoped || echo "not scoped")"

# --- the gate is judged by the RESULT BUNDLE's count, and the readout by the same one (#3243) --------
#
# suite-stats.test.sh proves the reading decides correctly and would keep passing if this runner never
# called it. A guard whose input nothing supplies is a value with no writer (L46), and this one has a
# second half that only exists here: the count feeding the SHORT RUN gate and the count printed in the
# readout must be the SAME number. Two independent readings of one run is how a readout comes to
# contradict the verdict beside it (L53).
# NOTE: this file defines its own assert_contains as (desc, NEEDLE, haystack), the reverse of the
# shared vocabulary in scripts/lib/shell-assertions.sh. Written the other way round first, and every
# assertion below passed while comparing the wrong pair.
RTL_SRC="$(cat "${SCRIPT_DIR}/run-tests-locked.sh" 2>/dev/null || echo "")"
assert_contains "the runner asks the run for its result bundle" "test_run_result_bundle" "${RTL_SRC}"
assert_contains "and reads the count out of it" "result_bundle_total_test_count" "${RTL_SRC}"
assert_contains "and decides which count wins in one place" "totals_with_authoritative_count" "${RTL_SRC}"
assert_contains "the gate is judged by that decision" \
  'executed="$(awk '"'"'{print $1}'"'"' <<< "${authoritative}")"' "${RTL_SRC}"
assert_contains "and the readout is handed the very same one" \
  'suite_report_for_run "${last_output}" "${MAC_DIR}" "${authoritative}"' "${RTL_SRC}"

# The restart refusal has to reach the runner too: it is passed through, not re-derived, so the runner
# cannot end up asking a different question than the one the fixture proved.
assert_contains "and the restart verdict is passed into that decision" \
  'totals_with_authoritative_count "$(test_run_totals "${last_output}")" "${bundle_count}" "${restarted}"' "${RTL_SRC}"

# --- #3392: the truncation retry, driven end to end -------------------------------------------------
#
# The decision has to be made INSIDE the retry loop, and every assertion above would keep passing with
# the reading left where it was, after the loop, where the retry can never see it (L3). This drives the
# real script with a stubbed xcodebuild whose log carries the exact signature of a time limit kill: a
# FAILED test line reporting a whole number of minutes to three decimals.
#
# Deliberately no `.xcresult` path in the log, so the bundle reading finds nothing to open and the
# output reading is what answers. That is the #3385 half, and it keeps the fixture off `xcresulttool`.
#
# NOTE: this file defines its own assert_contains as (desc, NEEDLE, haystack), the reverse of the shared
# vocabulary in scripts/lib/shell-assertions.sh.
TRUNCATED_RUN_LOG="Test Suite started
Test case 'RunStateIsPerSlotTests/aCheckStartedWhileAPrepIsLiveIsStillFollowed()' failed on 'My Mac - xctest (92479)' (60.000 seconds)
Test run with 5087 tests in 785 suites failed after 182.509 seconds.
Failing tests:
	RunStateIsPerSlotTests.aCheckStartedWhileAPrepIsLiveIsStillFollowed()

** TEST FAILED **"

TRUNCATED_RUN="$(run_wrapper_with_stub_xcodebuild "${TRUNCATED_RUN_LOG}" 65 "" "" "" "" 8643)"
assert_contains "a truncated run is retried" "Retrying once" "${TRUNCATED_RUN}"
assert_contains "and says the run was truncated rather than that the host crashed" \
  "TRUNCATED" "${TRUNCATED_RUN}"
assert_contains "and NAMES the test that was killed" \
  "aCheckStartedWhileAPrepIsLiveIsStillFollowed" "${TRUNCATED_RUN}"
assert_not_contains "and never blames the known host-crash flake for it" \
  "known self-hosted" "${TRUNCATED_RUN}"
# The retry is bounded, and the stub returns the same truncated log every time, so a run that retried
# without bound would never finish. That it finishes at all is the bound; this names it.
assert_contains "and the retry says which attempt it is" "attempt 2 of 2" "${TRUNCATED_RUN}"

# The other direction, so the change cannot have turned this into a runner that retries every red run.
# The same stub log WITHOUT the time limit line is an ordinary red and is run once.
ORDINARY_RED_LOG="Test Suite started
Test case 'SomeTests/aThing()' failed on 'My Mac - xctest (92479)' (0.013 seconds)
Test run with 8643 tests in 1179 suites failed after 182.509 seconds.
Failing tests:
	SomeTests.aThing()

** TEST FAILED **"
ORDINARY_RED="$(run_wrapper_with_stub_xcodebuild "${ORDINARY_RED_LOG}" 65 "" "" "" "" 8643)"
assert_not_contains "an ordinary red is not retried" "Retrying once" "${ORDINARY_RED}"
assert_not_contains "and is never described as truncated" "TRUNCATED" "${ORDINARY_RED}"

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All run-tests-locked.sh stale-host fixtures passed."
  exit 0
else
  echo "${FAILURES} run-tests-locked.sh stale-host fixture(s) failed."
  exit 1
fi
