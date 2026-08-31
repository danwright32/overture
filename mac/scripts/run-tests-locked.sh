#!/usr/bin/env bash
set -euo pipefail

# Runs the Mac app's tests under an exclusive flock, so a CI run on the self-hosted
# runner and a local or Claude session run never execute xcodebuild at the same time on
# this Mac (overlapping xcodebuild test runs otherwise produce a false TEST FAILED from a
# daemon timeout, not a real regression). Part of #478 (milestone 12), Phase 3 (#505).
#
# The lock file lives outside any repo checkout, at one fixed path: the CI job's checkout
# is wiped before every job, while a human or Claude session runs from the real checkout
# at a different absolute path, so only a fixed shared path makes the two actually
# contend for the same lock instead of each locking a separate file. Exits with
# xcodebuild's own exit code, so a caller sees a real pass or fail, not this wrapper
# always succeeding.
#
# #632: xcodebuild test boots the full Debug-configuration app as an app-hosted XCTest host,
# but never tears it down when the run finishes. Left running, it can shadow the current code
# the next time someone screenshots or interacts with the app (whichever window happens to be
# frontmost gets picked up non-deterministically). After the suite finishes, this kills any
# resident Debug test-host Overture.app process before exiting with xcodebuild's own code.

LOCK_FILE="/tmp/overture-mac-tests.lock"
# #2195: how many tests the last green run on this Mac executed. See the completeness check in main().
# Overridable so the shell fixtures point it at a throwaway path: they drive main() with a stubbed
# xcodebuild reporting a handful of tests, and against Dan's real baseline every one of those would read
# as a catastrophically short run. A test that can reach real state should be structurally unable to
# (L2), and this is also what stops a fixture rewriting the baseline the real gate is measured against.
BASELINE_FILE="${OVERTURE_TEST_BASELINE_FILE:-${HOME}/.overture-mac-test-baseline}"
# #2321: where a diagnostic the run cannot print in full is KEPT, and how many are kept there. The
# pure-suite fallback's output is the only artifact naming the cause of a failure this script cannot
# explain, and it used to be deleted on the line after the one that named it.
#
# A fixed directory holding a fixed number of files: several worktrees run this script on this Mac at
# once, so it is shared, and a shared directory that only ever grows is a second problem. Overridable
# for the same reason BASELINE_FILE is, so the shell fixtures are structurally unable to write into
# the real one (L2).
DIAGNOSTICS_DIR="${OVERTURE_TEST_DIAGNOSTICS_DIR:-${HOME}/.overture-mac-test-diagnostics}"
DIAGNOSTICS_KEEP=5
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# #3258: scratch that honours TMPDIR, so a leak is visible to the checks that look there.
# shellcheck source=../../scripts/lib/scratch.sh
. "${SCRIPT_DIR}/../../scripts/lib/scratch.sh"
# #2193/#2232: the suite's own shape, reported by the run instead of hand-written into a document.
# shellcheck source=./lib/suite-stats.sh
source "${SCRIPT_DIR}/lib/suite-stats.sh"
# #2577: whether the run is still MOVING, said while it runs. The empty-run gate below can only speak
# once a run has ended, and the run this exists for never ends.
# shellcheck source=./lib/test-progress-watch.sh
source "${SCRIPT_DIR}/lib/test-progress-watch.sh"

# shellcheck source=./lib/hosted-suite-stamp.sh
source "${SCRIPT_DIR}/lib/hosted-suite-stamp.sh"

# Given `ps -eo pid=,command=`-style output (one process per line: PID then its full command),
# returns the PIDs of any resident Debug-configuration Overture.app test host (#632): the one
# xcodebuild test boots at .../DerivedData/*/Build/Products/Debug/Overture.app/Contents/MacOS/Overture.
# A Release build (e.g. /Applications/Overture.app, from build-install.sh --launch) never matches,
# so it's never touched. Pure text match, so it's testable without touching real system state.
#
# #1671: takes the DerivedData path this run OWNS and kills nothing outside it. The kill sweeps run
# outside the flock (one before the lock is ever taken, one after it is released), so with two sessions
# on this Mac an unscoped matcher lets a finishing run kill the freshly launched host of a run that has
# just acquired the lock. The victim then dies with no named test failure, which is exactly the shape
# `run_outcome` calls "crashed" and `should_retry` retries as a known flake, so the retry that exists to
# absorb a genuine flake also hides this one and nothing points outside the victim's own code.
#
# An empty scope matches nothing at all, deliberately. This function only ever KILLS, so failing to
# resolve the scope must leave every process alone rather than fall back to matching all of them (L42).
stale_debug_test_host_pids() {
  local ps_output="$1" derived_root="${2:-}"
  [[ -n "${derived_root}" ]] || return 0
  echo "${ps_output}" \
    | grep -F "${derived_root}" \
    | grep -F '/Build/Products/Debug/Overture.app/Contents/MacOS/Overture' \
    | awk '{print $1}' || true
}

# The DerivedData directory THIS run builds into, which is what makes a host attributable to it.
# Resolved from xcodebuild itself rather than guessed, because the path carries a hash of the project's
# location and a wrong guess would silently scope the sweep to nothing.
own_derived_data_root() {
  local root
  root="$(xcodebuild -scheme Overture -showBuildSettings -json 2>/dev/null \
    | awk -F'"' '/"BUILD_DIR"/{print $4; exit}' \
    | sed -E 's#(/DerivedData/[^/]+)/.*#\1#')"
  # Anything that is not recognisably a DerivedData root is no answer at all, and no answer means the
  # sweep kills nothing. Fail-safe in the one direction that matters: this function only ever feeds a
  # `kill` (L42).
  [[ "${root}" == */DerivedData/* ]] && echo "${root}"
  return 0
}

# #1257: the PIDs of any running Debug Overture that is NOT the runner's own test host, i.e. the instance
# run-debug.sh launches from mac/build. It holds the single-instance lock (LSMultipleInstancesProhibited),
# so the test host cannot launch and the run dies after a full build (#1252 detects that; this lets main
# stop before building). Deliberately the complement of stale_debug_test_host_pids: same Debug-app anchor,
# but EXCLUDING /DerivedData/, because a DerivedData host is the runner's own spawn (safe to kill) while
# this instance is Dan's (which must never be auto-killed, so main asks him to quit it instead). The
# Release app (/Applications/Overture.app) lacks the Debug-products anchor and never matches.
blocking_debug_app_pids() {
  local ps_output="$1"
  echo "${ps_output}" \
    | grep -F '/Build/Products/Debug/Overture.app/Contents/MacOS/Overture' \
    | grep -Fv '/DerivedData/' \
    | awk '{print $1}' || true
}

# Did the run fail to COMPILE? (#1465)
#
# The tell is the compiler's own file:line:column shape, and xcodebuild's build-commands banner,
# NEVER the bare word "error". Every run of this suite prints CoreData noise carrying "error:", and a
# host that dies mid-run prints it too, so a naive grep would read the #1331 flake as a build failure
# and kill the retry that exists to absorb it.
#
# Only ever consulted AFTER the named-failure check below, so output that names failing tests is a
# failure whatever else it contains.
build_failed() {
  local output="$1"
  if grep -q '^The following build commands failed:' <<< "${output}"; then return 0; fi
  grep -qE '^[^[:space:]].*:[0-9]+:[0-9]+: (fatal )?error: ' <<< "${output}"
}

# Did xcodebuild fail to reach this Mac's TEST SERVICE, with no test having started? (#2322)
#
# Measured 2026-08-08: three consecutive runs reported "the test host crashed with no named test
# failure (a known self-hosted flake)" and were retried. The real cause was testmanagerd wedged
# since the previous Tuesday, so xctest hung before establishing a connection and ZERO tests
# executed. The message named the app host, which was blameless, the retry cost a second full build
# each time, and the investigation went down two wrong paths before the raw error was read.
#
# A crashed host and a machine that cannot start any test are different problems with different
# fixes (retry versus restart the service), and the evidence separating them was already here.
# BOTH halves are required, and the second is what keeps this from firing on an ordinary crash:
#   * the daemon's own wording, rather than a crash signature; and
#   * NO tests executed at all. A crash has a partial count, because it died partway through
#     something. A daemon timeout appearing in a run that DID execute tests is that ordinary crash,
#     and is still worth one retry (L104: test what the filter must preserve, not only what it
#     must catch).
test_service_wedged() {
  local output="$1"
  [[ -z "$(test_run_totals "${output}")" ]] || return 0
  grep -qaE 'hung before establishing connection|Timed out .*initiating control session' <<< "${output}" \
    && echo "wedged"
  return 0
}

# How old a test service has to be before it is worth mentioning (#2323), in days.
#
# Calibrated against a real reading rather than a round number: this Mac's testmanagerd was
# 2 days 8 hours old and perfectly healthy when measured on 2026-08-16, so a threshold below that
# would fire on the ordinary case and be ignored within a day (L93, L147). The wedged one on
# 2026-08-08 had been up since "the previous Tuesday", which is days further still.
TESTMANAGERD_OLD_DAYS=5

# testmanagerd_age_report <pid> <ps -o etime= output> [threshold days]. The advisory sentence when
# the machine's test service is old enough to be worth suspecting, and nothing otherwise (#2323).
#
# Advisory only and never blocking, matching prune-stale-registrations.sh: a long-lived daemon is
# usually fine, and this line only has to be in front of somebody at the moment a run fails oddly.
#
# `ps -o etime=` writes [[dd-]hh:]mm:ss, so days exist only when there is a "-", and a reading that
# does not parse yields NOTHING rather than falling through to a comparison that would score it as
# young (L50). Saying nothing is the right outcome for an advisory either way, but it must be
# reached by refusing to measure, not by measuring wrongly.
testmanagerd_age_report() {
  local pid="$1" etime="$2" threshold="${3:-${TESTMANAGERD_OLD_DAYS}}"
  pid="${pid//[[:space:]]/}"
  etime="${etime//[[:space:]]/}"
  [[ -n "${pid}" && -n "${etime}" ]] || return 0
  [[ "${etime}" =~ ^([0-9]+)-[0-9]{1,2}:[0-9]{2}:[0-9]{2}$ ]] || return 0
  local days=$((10#${BASH_REMATCH[1]}))
  [[ "${days}" -ge "${threshold}" ]] || return 0
  echo "this Mac's test service (testmanagerd, PID ${pid}) has been running for ${days} days. That is usually fine, so this is advisory and blocks nothing. It is here because on 2026-08-08 one this old was wedged: xctest hung before establishing a connection, three consecutive full suite runs executed no tests at all, and nothing on screen pointed at it. If this run fails oddly, restart it (launchd respawns it on demand) with: pkill -x testmanagerd"
}

# run_outcome <xcodebuild output> <exit code>. "crashed", "build-failed", "test-service-wedged",
# "failed", or "" for a pass.
#
# #1006: a killed run and a failing run must never look alike. On 2026-07-16 this printed
# `Test run with 1574 tests in 229 suites passed` for a ~2400-test suite and then died with
# `** TEST FAILED **` and an EMPTY `Failing tests:` list. ~800 tests never ran, the only number
# on screen said "passed", and it cost an hour to work out that nothing had actually failed.
#
# The tell is exact and needs no baseline: xcodebuild names every failing test under
# `Failing tests:`. If it reports failure and names NOTHING, nothing failed; the process died.
#
# Deliberately NOT a floor on the executed-test count. The two real crashes reported 1574 and
# 2069 of ~2400, so a floor loose enough to survive normal churn would have passed 2069, and a
# tight one would need bumping on every PR that adds a test. A guard people routinely bump is a
# guard people stop reading.
run_outcome() {
  local output="$1" code="$2"
  # #1252: a real pass ALWAYS prints "** TEST SUCCEEDED **". At exit 0 WITHOUT that banner the run did not
  # pass: most often the test HOST failed to LAUNCH (a running Debug app holds the single-instance lock),
  # which xcodebuild reports with EXIT 0 plus "Could not launch" / "** TEST FAILED **" and zero tests run.
  # Trusting the exit code alone read that dead run as a pass, so test-all.sh printed "all suites passed"
  # having run nothing. Require the positive banner, don't merely trust exit 0.
  if [[ "${code}" -eq 0 ]]; then
    grep -q '\*\* TEST SUCCEEDED \*\*' <<< "${output}" && return
    # #2322: asked here too, not only on the non-zero path. A run that never reached the test service
    # has no verdict of its own, and xcodebuild has been seen to exit 0 on a run that started nothing
    # (#1252), so the two can meet.
    if [[ -n "$(test_service_wedged "${output}")" ]]; then
      echo "test-service-wedged"
      return
    fi
    echo "crashed"
    return
  fi

  # Every line xcodebuild lists between "Failing tests:" and its verdict is a named failure. Read
  # through suite-stats.sh's parser rather than a second copy of the same awk, so this decision and
  # the list reprinted at the end of a failing run (#2600) can never disagree about what a named
  # failure is.
  local named
  named="$(failing_test_names "${output}" | grep -c . || true)"
  if [[ "${named}" -gt 0 ]]; then
    echo "failed"
    return
  fi
  # #1465: a run that never COMPILED has the same shape as a dead host (failed, nothing named), but it
  # is not a flake and retrying it just builds the same broken code a second time. Told apart before
  # falling through to "crashed", which is now only what it says: the run died.
  if build_failed "${output}"; then
    echo "build-failed"
    return
  fi
  # #2322: and a machine whose test service never answered is not a dead host either. Same shape
  # (failed, nothing named), different cause, different fix, and the retry below must not be spent
  # on it.
  if [[ -n "$(test_service_wedged "${output}")" ]]; then
    echo "test-service-wedged"
    return
  fi
  echo "crashed"
}

# #2195: how many tests a run actually executed, summed across every "Test run with N tests" line
# (the combined scheme prints one per target). Empty when the output names none, which is itself the
# answer for a run that died before any suite reported.
#
# #2193: reads that line through suite-stats.sh's parser rather than its own, so the short-run gate
# below and the shape readout at the end of a run can never disagree about how many tests ran. Two
# parsers of one line is exactly the drift this repo keeps finding (#1073, #987).
executed_test_count() {
  local totals
  totals="$(test_run_totals "$1")"
  [[ -n "${totals}" ]] && awk '{print $1}' <<< "${totals}"
  return 0
}

# run_is_scoped <args...>: whether this run was deliberately narrowed to a subset of the suite.
#
# ONLY a `-only-testing:` argument narrows a run. Every other argument (the parallel-testing flags, a
# destination, a result-bundle path) leaves the whole suite selected, and treating those as a scope
# turns the short-run gate OFF for a run that should be judged hardest.
#
# It used to be `[[ $# -gt 0 ]]`, any argument at all, and that is how #3234's parallel experiment came
# to be measured with no gate on it. Measured 2026-08-30: a parallel run executed 5,217 tests against a
# baseline of 8,618, lost the whole share of its second worker with no crash line anywhere, and printed
# an ordinary verdict, because passing `-parallel-testing-enabled YES` had marked it scoped. That is the
# gate switching itself off precisely where it was needed (L98, L259).
run_is_scoped() {
  local arg
  for arg in "$@"; do
    [[ "${arg}" == -only-testing:* ]] && return 0
  done
  return 1
}

# truncated_report <executed> <baseline>. Prints the sentence when a run came back materially short,
# and nothing when it did not.
#
# #2195: a run that dies partway through is indistinguishable from an ordinary red. Three consecutive
# runs on 2026-08-06 reported 4837, 4836 and 3932 tests against main's 5503, each naming a DIFFERENT
# innocent bystander that happened to be in flight when the process died. Between 600 and 1,500 tests
# never executed and nothing said so. Whoever sees the named test finds it passes in isolation, calls it
# a flake, re-runs, gets a different name, calls it a flake again, and ships. Since #1347 this run is the
# ONLY thing verifying the Mac app before it reaches main.
#
# The threshold is deliberately loose. It exists to catch a run that STOPPED, not to police churn: the
# observed truncations were 12% and 29% short, while a branch legitimately removing a suite might drop a
# percent or two. It asserts the QUANTITY it protects (how many tests ran) rather than a proxy for it,
# which is the objection `run_outcome` above records against a hand-maintained floor (L63).
truncated_report() {
  local executed="$1" baseline="$2"
  [[ -n "${executed}" && -n "${baseline}" && "${baseline}" -gt 0 ]] || return 0
  local floor=$(( baseline * 90 / 100 ))
  [[ "${executed}" -lt "${floor}" ]] || return 0
  echo "this run executed ${executed} tests, $(( baseline - executed )) fewer than the ${baseline} the last green run on this Mac ran. The result is NOT trustworthy: the process almost certainly died partway through, and any test named below was merely in flight when it did, not the cause."
}

# nothing_executed_report <exit_code> <executed>. Prints the sentence when a run reported success while
# executing no tests at all, and nothing otherwise.
#
# #2317: a scoped run whose `-only-testing:` path matches nothing prints "** TEST SUCCEEDED **" and exits
# 0, having run zero tests. Hit again on 2026-08-08 while verifying #1994: the scope named one test that
# did not resolve, reported success against a deliberately stale file that should have failed it, and the
# same scope at suite level then failed correctly. AGENTS.md documented the trap and told the reader to
# grep the output for the test name, which makes the safety net somebody remembering to be suspicious of
# a run that just said it passed. Since #1347 this run is the ONLY thing verifying the Mac app before it
# reaches main.
#
# Deliberately separate from truncated_report. A SHORT RUN started and died partway; this one never
# started anything, and the two want different responses (re-run and look for what is killing the
# process, versus fix the scope you typed). Only a run REPORTING SUCCESS is judged here: a build failure
# and a dead host both arrive with no count too, and each already explains itself, so adding this
# sentence to a red run would put a second, wrong explanation in front of the real one.
nothing_executed_report() {
  local exit_code="$1" executed="$2"
  [[ "${exit_code}" -eq 0 ]] || return 0
  [[ -z "${executed}" || "${executed}" -eq 0 ]] || return 0
  echo "this run reported success but executed NO tests at all. Nothing was verified. A -only-testing: scope that matches nothing (a wrong suite or test name, or a @Suite display name that differs from its Swift type name) does exactly this: xcodebuild prints ** TEST SUCCEEDED ** and exits 0."
}

# should_retry <outcome> <attempt> <max_attempts>. Prints "retry" when another attempt should run.
#
# #1331: the self-hosted swift-tests runner intermittently crashes the test HOST mid-run ("Restarting
# after unexpected exit" / the host could not launch). On a merge commit's push-CI that reds main even
# though the PR passed and the suite passes locally, and merge-when-green then refuses the next PR until
# someone reruns by hand. A "crashed" outcome (run_outcome above: the run DIED, with no NAMED test
# failure) is a known flake, so retry it ONCE. A genuine "failed" (named tests) is NEVER retried, or the
# guard would paper over a real red; a pass ("") is never retried either. The crash/failure distinction
# is exactly run_outcome's, so this can never retry a real failure.
#
# #1465: "build-failed" is likewise never retried. A run that never compiled has a dead host's SHAPE
# (failed, nothing named) but none of its cause, so a second attempt just builds the same broken code
# and prints the same errors again. Telling the two apart is run_outcome's job, so nothing changes
# here beyond the outcome it is handed.
should_retry() {
  local outcome="$1" attempt="$2" max_attempts="$3"
  [[ "${outcome}" == "crashed" && "${attempt}" -lt "${max_attempts}" ]] && echo "retry"
  return 0
}

# should_probe_pure_suite <outcome>. Prints "probe" when the pure suite's verdict is worth asking for.
#
# #1967: the 4,802 pure tests do not need the app. They live in the OvertureCore scheme, which does not
# build the app target at all, so a broken app cannot fail them, slow them, or stop them reporting.
# Measured on 2026-08-02 with a deliberate `fatalError()` in OvertureApp.init: that scheme printed
# "Test run with 4802 tests in 690 suites passed", "** TEST SUCCEEDED **", and exit 0.
#
# So when the combined run DIES (the host crashed: no named test failure), one red verdict over the
# whole thing hides the fact that every domain test passed. Ask the pure suite directly and say so.
#
# Only ever on a crash. A genuine "failed" names the tests that failed, so the answer is already known
# and a second run would only bury the list; "build-failed" never compiled, so nothing ran at all; and a
# pass has nothing to add.
should_probe_pure_suite() {
  local outcome="$1"
  [[ "${outcome}" == "crashed" ]] && echo "probe"
  return 0
}

# --- naming the cause of a dead run from the host's own log (#1972) ------------------------
#
# A crash says WHICH kind of red it is (#1006) but never said WHY, and the causes it printed were a
# guess: a hardcoded list naming a Debug app holding the single-instance lock and an overlapping run
# on this Mac. On 2026-08-01 the real cause was neither. The app's menu bar item had been removed,
# which terminates a MenuBarExtra app and so its test host (#1966), and the wrong hint sent hours of
# elimination in the wrong direction (clean main, deleted DerivedData, store locks, disk space,
# crash reports, 78 stale LaunchServices registrations, a full restart). The two decisive lines were
# in the operating system's own log the whole time.
#
# The three below are pure text over already-captured output, so they are testable without a dead
# host; main asks `log show` on the crash path only.

# The dead host's PID, read out of the prefix it stamps on every line it logs through xcodebuild
# (`Overture[37030:38151440]`). That prefix is the only place its identity survives: by the time the
# run is declared dead the process is gone, so the process table cannot answer. Empty when the host
# never launched at all, which is a real case (it is this issue's title) and must never be filled in
# with a PID nobody observed, since the log predicate is built from it.
#
# The LAST one wins: xcodebuild relaunches the host after an unexpected exit, so one attempt's
# output can carry two, and the one whose death ended the run is the later.
host_pid_from_output() {
  local output="$1"
  grep -aoE 'Overture\[[0-9]+:[0-9]+\]' <<< "${output}" \
    | tail -1 \
    | sed -E 's/^Overture\[([0-9]+):.*/\1/' \
    || true
}

# What to ask `log show` about: the exact process when its PID was observed, and the app by name
# when it was not. Asking by name is wider (it would also match a Debug or Release Overture running
# alongside), which is why it is the fallback rather than the default.
host_log_predicate() {
  local pid="$1"
  if [[ -n "${pid}" ]]; then
    echo "processID == ${pid}"
  else
    echo 'process == "Overture"'
  fi
}

# A `log show` dump cut down to the lines that name a cause: a termination, the status bar (whose
# removal is what killed the host in #1966), a TCC privacy denial, or the store refusing to open
# (#663). A --debug --info dump over a ~90 second run is thousands of lines of framework chatter, so
# printing it whole would bury the two that matter, which is the same defect as printing nothing.
#
# Capped at the last 40, and deliberately the LAST: the lines nearest the death are the ones that
# describe it.
host_log_evidence() {
  local log_output="$1"
  grep -aiE 'terminat|StatusBar|TCC|store[ -]unavailable' <<< "${log_output}" | tail -40 || true
}

# Prints what the host's own log says about why it died, or says plainly that it named nothing.
# window_seconds is how far back to look, sized to how long the run actually took, so the dump
# covers the run and no more.
report_host_log_evidence() {
  local host_pid="$1" window_seconds="$2"
  local predicate evidence

  predicate="$(host_log_predicate "${host_pid}")"
  evidence="$(host_log_evidence "$(log show --last "${window_seconds}s" --debug --info --predicate "${predicate}" 2>/dev/null || true)")"

  echo >&2
  if [[ -n "${evidence}" ]]; then
    echo "run-tests-locked.sh: the host's own log (${predicate}) says why:" >&2
    sed 's/^/  /' <<< "${evidence}" >&2
  else
    echo "run-tests-locked.sh: the host's own log named no cause. Read it in full with:" >&2
    echo "  log show --last ${window_seconds}s --debug --info --predicate '${predicate}'" >&2
    echo "Causes actually seen here: the menu bar item being removed, which terminates the app and" >&2
    echo "so its test host (#1966); a Debug Overture holding the single-instance lock (#1257, which" >&2
    echo "this script checks before building); an overlapping xcodebuild on this Mac (#1331)." >&2
  fi
}

# --- keeping the evidence when the runner cannot explain a failure (#2321) ------------------
#
# The pure-suite fallback (#1967) is the last thing this script tries when a run dies. Its output
# goes to a FILE and never to the screen, because on the common path it is only asked for one line
# ("the PURE suite PASSED, N tests"). When it does NOT pass, that file is the only artifact anywhere
# naming the cause, and the message that named it was followed on the very next line by `rm -f`.
#
# Measured 2026-08-08: three consecutive full runs failed this way. The message sent the
# investigation at the app host, then at an external kill, both wrong, and the cause was recovered
# only by reproducing the run by hand for another 20 minutes to produce output that had already
# existed twice. Since #1347 this run is the ONLY thing verifying the Mac app before it reaches main,
# so the case where it cannot explain itself is exactly the case that must not cost an hour.
#
# Both halves are done, deliberately, because neither alone is enough: the handful of lines that name
# the cause are PRINTED (a path is not an answer, and the whole file is thousands of lines of build
# chatter), and the whole file is KEPT (this filter only knows the shapes seen so far, so the next
# cause it has never met must still be readable somewhere).

# pure_failure_evidence <pure suite output>. The lines that name WHY the pure suite did not pass:
# every test it named as failing, plus the infrastructure lines that explain a run which named none.
#
# The infrastructure patterns are exact shapes, never the bare word "error", for the same reason
# build_failed above is: every run of this suite prints CoreData noise carrying "error:", and a
# filter that keeps that buries the lines that matter, which is the same defect as printing nothing.
pure_failure_evidence() {
  local output="$1" named infra
  # The same block run_outcome reads to decide "failed": every line xcodebuild lists under
  # "Failing tests:" is a named failure, and on a pure-suite failure those names ARE the evidence.
  named="$(failing_test_names "${output}" | head -20 || true)"
  # A wedged testmanagerd (2026-08-08), a host that could not launch, a relaunch after an unexpected
  # exit, and code that did not compile. The LAST of these are the ones nearest the death.
  infra="$(grep -aE 'encountered an error|Timed out |Could not launch|Restarting after unexpected exit|^[^[:space:]].*:[0-9]+:[0-9]+: (fatal )?error: ' <<< "${output}" \
    | tail -20 || true)"
  printf '%s\n%s\n' "${named}" "${infra}" | grep -a '[^[:space:]]' | tail -20 || true
}

# keep_diagnostic_file <source file> [dir] [keep]. Copies the file somewhere it OUTLIVES the run and
# prints the path it kept it at, then prunes the directory to the newest <keep> diagnostics. Prints
# nothing when it could not keep it, so the caller says what actually happened rather than naming a
# path that does not exist, which is the whole defect this exists to fix (L11).
#
# mktemp does the naming, so two worktrees crashing in the same second get two files rather than one
# silently overwriting the other at exactly the moment both are worth reading. The timestamp leads,
# so a plain name sort is oldest-first and the prune below needs no stat of any kind.
keep_diagnostic_file() {
  local source_file="$1" dir="${2:-${DIAGNOSTICS_DIR}}" keep="${3:-${DIAGNOSTICS_KEEP}}"
  local kept old
  mkdir -p "${dir}" 2>/dev/null || return 0
  kept="$(mktemp "${dir}/pure-suite-$(date +%Y%m%d-%H%M%S).XXXXXX" 2>/dev/null)" || return 0
  cp "${source_file}" "${kept}" 2>/dev/null || { rm -f "${kept}"; return 0; }
  # Bounded by deleting the OLDEST, so the shared directory stays a fixed size however many runs
  # crash. `sort -r` puts the newest first; everything past the keep count is older than all of them.
  while IFS= read -r old; do
    [[ -n "${old}" ]] && rm -f "${old}"
  done < <(find "${dir}" -maxdepth 1 -name 'pure-suite-*' -type f 2>/dev/null \
    | sort -r | tail -n "+$(( keep + 1 ))")
  echo "${kept}"
}

main() {
  command -v flock >/dev/null || { echo "flock not found; install it with: brew install flock" >&2; exit 1; }

  # #2577: however this script leaves, its watcher goes with it. A watcher that outlived the run
  # would sit printing stall warnings about a temporary file nobody is writing to any more, which is
  # a worse alarm than none: it would be indistinguishable from a real one and always wrong.
  trap 'stop_progress_watch "${PROGRESS_WATCH_PID}"' EXIT

  cd "${MAC_DIR}"

  # #1257: prevent, don't just detect (#1252). A Debug Overture run-debug.sh launched from mac/build holds
  # the single-instance lock, so the test host cannot launch and the whole run dies AFTER a full build. Stop
  # here, before building, with the one instruction that fixes it. A stale DerivedData test host from a prior
  # aborted run would block the same way, but it is the runner's OWN spawn and safe to clear, so clear it
  # rather than nag; the mac/build instance is Dan's and is never auto-killed.
  # #1671: scoped to this run's own DerivedData, so a concurrent session's live host is never a candidate.
  local derived_root stale_pid
  derived_root="$(own_derived_data_root)"
  for stale_pid in $(stale_debug_test_host_pids "$(ps -eo pid=,command=)" "${derived_root}"); do
    kill "${stale_pid}" 2>/dev/null || true
  done
  local blockers blocker_pids
  blockers="$(blocking_debug_app_pids "$(ps -eo pid=,command=)")"
  if [[ -n "${blockers}" ]]; then
    blocker_pids="$(echo "${blockers}" | paste -sd ',' -)"
    echo "run-tests-locked.sh: a Debug Overture is running (PID ${blocker_pids}) and holds the single-instance" >&2
    echo "lock, so the test host cannot launch and the run would die after a full build." >&2
    echo "Quit the Debug app (Cmd+Q only backgrounds it; quit it from the menu bar) and rerun. See #1257." >&2
    exit 1
  fi

  # #2323: how old this Mac's test service is, read BEFORE anything takes the lock, so a run that
  # then sits queued behind another worktree's suite still carries the line. One cheap read, and on
  # 2026-08-08 it was the whole answer while nothing on screen pointed at it.
  local daemon_pid="" daemon_age="" daemon_advisory=""
  daemon_pid="$(pgrep -x testmanagerd 2>/dev/null | head -1 || true)"
  [[ -n "${daemon_pid}" ]] && daemon_age="$(ps -o etime= -p "${daemon_pid}" 2>/dev/null || true)"
  daemon_advisory="$(testmanagerd_age_report "${daemon_pid}" "${daemon_age}")"
  if [[ -n "${daemon_advisory}" ]]; then
    echo "run-tests-locked.sh: ${daemon_advisory}" >&2
  fi

  # #1331: run the suite, and if the HOST crashes (the run died with no named test failure, a known
  # self-hosted flake) retry once. A genuine failure or a pass is never retried (see should_retry).
  local test_exit_code=0 outcome="" attempt=1 max_attempts=2 output_file pid
  local host_pid="" started_at=0 log_window=60 last_output=""
  while true; do
    test_exit_code=0
    started_at="${SECONDS}"
    output_file="$(overture_scratch_file run-tests-output)"
    # #3276: where the live store suite records the corpus counts it measured.
    #
    # The corpus line is a `print()` from a test, and a PARALLEL worker's stdout does not reach
    # xcodebuild's: measured 2026-08-30, the suite ran and passed and the line appeared zero times in
    # 10,059 lines. A file is a channel a worker process actually has.
    #
    # xcodebuild forwards only `TEST_RUNNER_`-prefixed variables to the test process and strips the
    # prefix, so the bare name would be silently ignored.
    #
    # A FRESH path per attempt, deliberately. A fixed one would let the previous run's numbers be read
    # as this one's, and a retry after a crash would report the crashed attempt's corpus as its own
    # (L133, L98). The suite writes it only when it actually measures, so an absent file and a measured
    # zero stay different facts.
    corpus_file="$(overture_scratch_file live-corpus)"
    rm -f "${corpus_file}"
    export TEST_RUNNER_OVERTURE_CORPUS_FILE="${corpus_file}"
    # #2577: watch this attempt's own log while it streams. Started BEFORE flock, deliberately, so
    # the wait for the shared lock is inside what the watcher can see: an empty log is how it knows
    # the run is queued rather than stalled, and a run that sits behind another worktree's suite for
    # 50 minutes says so instead of being silent for 50 minutes.
    start_progress_watch "${output_file}"
    # tee, so the run still streams live: a suite that only prints at the end looks hung (#1006's
    # investigation was slow enough without waiting blind).
    #
    # #1459: read PIPESTATUS with NOTHING run in between, so `set +e` here rather than `|| true` on
    # the pipeline. Both survive `set -e`, but under `pipefail` a red xcodebuild fails the whole
    # pipeline, which is exactly when `|| true` runs, and `true` is itself a pipeline, so it
    # overwrites PIPESTATUS with (0):
    #
    #   bash -c 'set -euo pipefail; (exit 65) | tee /dev/null || true; echo ${PIPESTATUS[0]}'  -> 0
    #
    # So test_exit_code read 0 on precisely the runs where it should read 65, run_outcome took its
    # exit-0 branch, and every genuine failure came back "crashed": retried as a #1331 flake, its
    # `Failing tests:` list buried, and signed off with "the code was never the problem". The exact
    # inverse of the distinction #1006 built.
    set +e
    # #2317: extra arguments are forwarded to xcodebuild, so a SCOPED run can go through this wrapper
    # instead of around it. That matters because the trap the empty-run gate below exists for is a
    # `-only-testing:` path that matches nothing, and until now the only way to pass one was to invoke
    # xcodebuild directly, which is precisely the path with no gate on it. Usage:
    #
    #   mac/scripts/run-tests-locked.sh -only-testing:OvertureTests/StoreSchemaGuardTests
    #
    # With no arguments this is exactly what it always was: the whole suite.
    flock "${LOCK_FILE}" xcodebuild -scheme Overture -destination 'platform=macOS' test "$@" \
      2>&1 | tee "${output_file}"
    test_exit_code="${PIPESTATUS[0]}"
    set -e
    # The run is over, so the watcher has nothing left to watch and the log is about to be deleted.
    # Stopped here rather than only in the trap, because a retried attempt starts another one.
    stop_progress_watch "${PROGRESS_WATCH_PID}"

    for pid in $(stale_debug_test_host_pids "$(ps -eo pid=,command=)" "${derived_root}"); do
      kill "${pid}" 2>/dev/null || true
    done

    # #1006: say WHICH kind of red this is. "** TEST FAILED **" with nothing named means the process
    # died, not that a test failed, and reading it as a test failure sends whoever sees it hunting for
    # a bug that does not exist.
    outcome="$(run_outcome "$(cat "${output_file}")" "${test_exit_code}")"
    # #1972: captured before the output is discarded, since the dead host's PID survives nowhere
    # else. The window is this attempt's own duration plus a margin for the launch that precedes
    # its first log line, so the dump covers the run and no more.
    host_pid="$(host_pid_from_output "$(cat "${output_file}")")"
    log_window=$(( SECONDS - started_at + 30 ))
    # #2195: kept so the completeness check below can read this attempt's counts. The file itself still
    # goes, since it holds the whole streamed log.
    last_output="$(cat "${output_file}")"
    # #3276: read BEFORE the scratch file goes, and kept per attempt for the same reason `last_output`
    # is: a retry's reading must be the retry's own.
    last_corpus_file_text="$(cat "${corpus_file}" 2>/dev/null || true)"
    rm -f "${output_file}" "${corpus_file}"

    [[ -z "$(should_retry "${outcome}" "${attempt}" "${max_attempts}")" ]] && break
    echo >&2
    echo "run-tests-locked.sh: the test host crashed with no named test failure (a known self-hosted" >&2
    echo "flake, #1331). Retrying once (attempt $((attempt + 1)) of ${max_attempts})..." >&2
    attempt=$((attempt + 1))
  done

  # #2195: before anything reads the outcome, say whether the run was COMPLETE. A truncated run is none
  # of passed, failed or crashed: it is a result that cannot be believed either way, and it has to say so
  # by name rather than let a bystander take the blame.
  #
  # The expected count lives beside the lock this script already owns and NOT in the repo, because a
  # checked-in number is one somebody has to remember to bump, and a guard people routinely bump is a
  # guard people stop reading. It is written from this script's own last green run, so it maintains
  # itself (L41). No baseline yet means no claim: the first green run records one.
  #
  # #2317: the baseline is a FULL-SUITE number, so neither the comparison nor the write applies to a run
  # that was deliberately scoped. A scoped run legitimately executes a handful of tests, which would read
  # as a 99% truncation, and a green one would then overwrite the baseline with that handful and disable
  # the gate for every full run after it. The empty-run gate below is judged on every run either way,
  # because "nothing ran" is never correct.
  local executed baseline="" truncated="" scoped=0 restarted=""
  run_is_scoped "$@" && scoped=1
  # #2821: whether the test process was RELAUNCHED partway through, which makes every count below a
  # count of the REMAINDER rather than of this run.
  restarted="$(test_run_restarted "${last_output}")"
  # #3266: the half the log cannot show. A test killed at its `.timeLimit` makes xcodebuild relaunch the
  # test process and print NOTHING about it, so the totals below are the totals of the remainder and the
  # log-based check above stays silent. Read from the result bundle, and only when the log said nothing,
  # so the cheaper reading still wins where it works.
  if [[ -z "${restarted}" ]]; then
    TIME_LIMIT_KILL="$(result_bundle_time_limit_kill "$(test_run_result_bundle "${last_output}")")"
    [[ -n "${TIME_LIMIT_KILL}" ]] && restarted="time-limit ${TIME_LIMIT_KILL}"
  fi

  # #3243 / #3265: the count that decides everything below comes from the run's own RESULT BUNDLE where
  # one can be read, and from the log text only where one cannot. Two reasons, and the second is the
  # sharper one. A parallel run's stdout is written by several workers at once and their per-test lines
  # can collide, so a count parsed from it is short by however many collided and nothing bounds that.
  # And the short-run gate compares this number against a baseline a SERIAL run recorded, which used to
  # be produced a different way: `totalTestCount` is one quantity, by test NAME, however the run was
  # parallelised, so both sides of that comparison are now the same thing.
  #
  # It costs one `xcresulttool` call, measured at 6.2s against a suite of about 330s.
  local bundle_count authoritative
  bundle_count="$(result_bundle_total_test_count "$(test_run_result_bundle "${last_output}")")"
  authoritative="$(totals_with_authoritative_count "$(test_run_totals "${last_output}")" "${bundle_count}" "${restarted}")"
  executed="$(awk '{print $1}' <<< "${authoritative}")"
  if [[ "${scoped}" -eq 0 ]]; then
    [[ -f "${BASELINE_FILE}" ]] && baseline="$(cat "${BASELINE_FILE}" 2>/dev/null || true)"
    truncated="$(truncated_report "${executed}" "${baseline}")"
  fi
  if [[ -n "${truncated}" ]]; then
    echo >&2
    echo "run-tests-locked.sh: SHORT RUN. ${truncated}" >&2
    echo "Re-run the suite. If it comes back short again, something is killing the process (#2195, #1006)." >&2
    echo >&2
    # And it FAILS. The dangerous case is precisely a short run that still prints a success banner
    # (#1006 saw one: "Test run with 1574 tests ... passed" over a ~2400-test suite), because
    # test-all.sh would go on to say "all suites passed" having run two thirds of it. A result that
    # cannot be believed must never exit 0.
    [[ "${test_exit_code}" -ne 0 ]] || test_exit_code=1
  elif [[ "${scoped}" -eq 0 && -z "${outcome}" && -n "${executed}" && -z "${restarted}" ]]; then
    # Only a genuinely green FULL run may move the baseline, so neither a truncated one, nor a failing
    # one, nor a scoped one can quietly lower the bar it is measured against.
    #
    # #2821: nor a RESTARTED one, which is the same hazard arriving by a different route. Its count
    # is the remainder that ran after the relaunch, and a green one would record that remainder as
    # the bar every later run is measured against, which disables the SHORT RUN gate above for
    # everything after it. A restarted run that ends RED is already caught by that gate whenever a
    # baseline exists; this closes the green case, which is the one that writes.
    echo "${executed}" > "${BASELINE_FILE}"
  fi

  # #2317: and a run that executed NOTHING is not a pass either. Checked after the baseline write above
  # so an empty run can never record itself as the count to measure the next one against, which would
  # disable the short-run gate as well.
  local nothing_ran
  nothing_ran="$(nothing_executed_report "${test_exit_code}" "${executed}")"
  if [[ -n "${nothing_ran}" ]]; then
    echo >&2
    echo "run-tests-locked.sh: NOTHING RAN. ${nothing_ran}" >&2
    echo "Check the -only-testing: path you passed, or run the whole suite with no scope at all." >&2
    echo >&2
    test_exit_code=1
  fi

  # #2193/#2232: the suite's shape, every run, pass or fail. It is printed unconditionally because
  # the number's job is to be a reference someone can check a suspicious run against, and the runs
  # worth checking are the odd ones. AGENTS.md used to carry these figures by hand and both had
  # drifted, one by 768 tests, which quietly weakened the very warning it was giving about a scoped
  # run that executes nothing. A readout the run produces itself cannot drift.
  echo >&2
  echo "run-tests-locked.sh: $(suite_report_for_run "${last_output}" "${MAC_DIR}" "${authoritative}")" >&2

  # #2991: and whether the LIVE store invariants measured anything, AND FOR HOW LONG THEY HAVE NOT,
  # beside the shape rather than buried thousands of lines up in the log. The corpus line has been
  # printed since #2986; nobody was scheduled to read it, and it sat at zero on both invariants
  # (measured 2026-08-19) while they passed. A zero nobody reads stops being a measurement and becomes
  # proof the thing cannot occur (L182), which is the one reading this must never allow.
  #
  # The duration is the half worth acting on, and it needs a record. That record lives beside the
  # repo, is per machine by nature (it records what ran HERE), and is gitignored, on the exact
  # precedent of `.overture-eval-last-run` (#1867). The DATE lives INSIDE the file rather than being
  # its modification time, for that file's own reason: a clone rewrites every mtime, so an mtime would
  # reset the dormancy to zero the first time anyone cloned, which is the one number this must never
  # get wrong.
  #
  # The clock is computed HERE and passed in, so the reporting itself stays pure and its fixture can
  # pin both ends (L130).
  # OVERRIDABLE, and that is not a convenience. This fixture drives the REAL wrapper, so without a seam
  # its "measuring" case wrote a record into the actual repository root, claiming both invariants had
  # measured rows on a day the live store held none. A test must be structurally unable to write into
  # the live tree (L2), and a default that only the fixture can move is what makes that structural
  # rather than remembered. Caught by reading the file after a run, not by any check.
  LIVE_CORPUS_RECORD="${OVERTURE_LIVE_CORPUS_RECORD:-${MAC_DIR}/../.overture-live-corpus-seen}"
  LIVE_CORPUS_TODAY="$(date +%Y-%m-%d)"
  LIVE_CORPUS_SEEN="$(cat "${LIVE_CORPUS_RECORD}" 2>/dev/null || true)"
  echo "run-tests-locked.sh: $(live_corpus_report "${last_output}" "${LIVE_CORPUS_TODAY}" "${LIVE_CORPUS_SEEN}" "${last_corpus_file_text:-}")" >&2
  # Written only when this run actually measured something. `live_corpus_seen_update` decides that and
  # returns the whole new contents, so a dormant run and a scoped run both come back unchanged and the
  # last real measurement is preserved rather than stamped over.
  LIVE_CORPUS_NEXT="$(live_corpus_seen_update "${last_output}" "${LIVE_CORPUS_TODAY}" "${LIVE_CORPUS_SEEN}" "${last_corpus_file_text:-}")"
  if [[ -n "${LIVE_CORPUS_NEXT}" && "${LIVE_CORPUS_NEXT}" != "${LIVE_CORPUS_SEEN}" ]]; then
    printf '%s\n' "${LIVE_CORPUS_NEXT}" > "${LIVE_CORPUS_RECORD}" 2>/dev/null || true
  fi

  # #1995: and whether THIS run verified the screens, beside the two readouts above.
  #
  # The hosted tests are the only ones that render a real SwiftUI view, and since #1967 a launch fault
  # costs them alone: the pure suite passes, this script says so, and work carries on correctly. What
  # nothing recorded is when they last actually ran, so a host broken across a stretch of UI work leaves
  # the screens unverified for as long as that lasts, silently, while the work most likely to be happening
  # in that window is exactly the work they cover.
  #
  # Judged by the hosted suites' OWN names, derived from the directory rather than listed anywhere, so a
  # run that names one of them as passed really did render a view. A scoped pure run, a crashed host and a
  # build failure all correctly report NOT VERIFIED, and each leaves the record alone rather than stamping
  # today over the last real pass.
  #
  # Overridable for the same structural reason as the record above: the fixture drives the real wrapper,
  # so a default only it can move is what keeps a test out of the live tree (L2).
  HOSTED_STAMP_RECORD="${OVERTURE_HOSTED_SUITE_RECORD:-${MAC_DIR}/../.overture-hosted-suite-seen}"
  HOSTED_STAMP_TODAY="$(date +%Y-%m-%d)"
  HOSTED_STAMP_SEEN="$(cat "${HOSTED_STAMP_RECORD}" 2>/dev/null || true)"
  HOSTED_SUITE_NAMES="$(hosted_suite_names "${MAC_DIR}/OvertureHostedTests")"
  # #3233: the TYPE names beside the display ones. A parallel run prints no `Suite "..." passed` line
  # at all and names each suite by its type, so without these the screens read as unverified on every
  # run under that flag, by runs that had just rendered all of them.
  HOSTED_SUITE_TYPES="$(hosted_suite_types "${MAC_DIR}/OvertureHostedTests")"
  HOSTED_VERIFIED="$(hosted_suites_ran "${last_output}" "${HOSTED_SUITE_NAMES}" "${HOSTED_SUITE_TYPES}")"
  while IFS= read -r hosted_line; do
    [[ -n "${hosted_line}" ]] && echo "run-tests-locked.sh: ${hosted_line}" >&2
  done <<< "$(hosted_freshness_line "${HOSTED_VERIFIED}" "$(hosted_stamp_date "${HOSTED_STAMP_SEEN}")" \
                                    "${HOSTED_STAMP_TODAY}" "${HOSTED_SUITE_NAMES}")"
  HOSTED_STAMP_NEXT="$(hosted_stamp_update "${HOSTED_VERIFIED}" "${HOSTED_STAMP_TODAY}" "${HOSTED_STAMP_SEEN}")"
  if [[ -n "${HOSTED_STAMP_NEXT}" && "${HOSTED_STAMP_NEXT}" != "${HOSTED_STAMP_SEEN}" ]]; then
    printf '%s' "${HOSTED_STAMP_NEXT}" > "${HOSTED_STAMP_RECORD}" 2>/dev/null || true
  fi

  # #2322: no test started at all, and the evidence says the machine rather than the change. Said
  # before the crash branch below, and INSTEAD of it, because a crashed host and a machine that
  # cannot start any test want different actions and must never share one message.
  if [[ "${outcome}" == "test-service-wedged" ]]; then
    echo >&2
    echo "run-tests-locked.sh: NO TEST RAN, and the evidence points at this MACHINE rather than at" >&2
    echo "your change. xcodebuild could not reach the test service: the runner hung before" >&2
    echo "establishing a connection, or the control session with the testmanagerd daemon timed out," >&2
    echo "and not one test executed. The app host is blameless here." >&2
    echo "Nothing was retried and the pure suite was not asked: both go through that same daemon, so" >&2
    echo "each would meet the same wedge after paying for another full build." >&2
    echo "Restart it (launchd respawns it on demand) and run again:" >&2
    echo "  pkill -x testmanagerd" >&2
    echo "See #2322, #2323." >&2
  fi

  if [[ "${outcome}" == "build-failed" ]]; then
    echo >&2
    echo "run-tests-locked.sh: the code did not COMPILE, so no test ran. The errors are above." >&2
    echo "Nothing was retried: this is not the #1006 host crash and not a flake. See #1465." >&2
  fi

  if [[ "${outcome}" == "crashed" ]]; then
    echo >&2
    echo "run-tests-locked.sh: the test run CRASHED. It did not pass and it did not fail: the run died." >&2
    echo "Any count printed above is not a pass. If a rerun passes, the code was never the problem. See #1006." >&2

    # #1972: say WHY from the host's own log instead of guessing at it. Only here, never on a pass
    # or a build failure: the dump is slow and there is no dead host to explain.
    report_host_log_evidence "${host_pid}" "${log_window}"

    # #1967: a crash used to end here, with one red verdict standing over 4,802 tests that need no app
    # and may well have passed. The pure suite has its own scheme with the app target left out, so ask it.
    if [[ -n "$(should_probe_pure_suite "${outcome}")" ]]; then
      echo >&2
      echo "run-tests-locked.sh: asking the PURE suite directly, since it does not need the app..." >&2
      local pure_output pure_code=0 pure_outcome
      pure_output="$(overture_scratch_file pure-suite-output)"
      # #2577: the SIBLING of the run above, and the identical shape: flock, then xcodebuild, into a
      # file. It queues for the same lock and runs the same tests, so it can wait the same way and
      # hang the same way, and it is reached at the worst possible moment (after a crash, when
      # somebody is already waiting on an answer). Watched by the same watcher rather than left as
      # the one path where a hang is still invisible (L30).
      start_progress_watch "${pure_output}"
      set +e
      flock "${LOCK_FILE}" xcodebuild -scheme OvertureCore -destination 'platform=macOS' test \
        > "${pure_output}" 2>&1
      pure_code="$?"
      set -e
      stop_progress_watch "${PROGRESS_WATCH_PID}"
      pure_outcome="$(run_outcome "$(cat "${pure_output}")" "${pure_code}")"
      echo >&2
      if [[ -z "${pure_outcome}" ]]; then
        echo "run-tests-locked.sh: the PURE suite PASSED. $(grep -aoE 'Test run with [0-9]+ tests in [0-9]+ suites passed after [0-9.]+ seconds' "${pure_output}" | tail -1)" >&2
        echo "So the domain logic is fine and the failure above is the APP HOST, not your code. What is" >&2
        echo "unverified is only the hosted tests (the handful that render a real SwiftUI view)." >&2
      else
        # #2321: this is the one branch where the script has nothing left to say about the cause, so
        # the diagnostic is the whole value of the message. Say what the output names, and keep the
        # output, instead of naming a file and deleting it on the next line.
        local pure_evidence pure_kept
        pure_evidence="$(pure_failure_evidence "$(cat "${pure_output}")")"
        pure_kept="$(keep_diagnostic_file "${pure_output}")"
        echo "run-tests-locked.sh: the PURE suite also did not pass (${pure_outcome}), so this is NOT" >&2
        echo "just a host problem." >&2
        if [[ -n "${pure_evidence}" ]]; then
          echo "What its output names as the cause:" >&2
          sed 's/^/  /' <<< "${pure_evidence}" >&2
        else
          echo "Its output named no cause in any shape this script knows how to read." >&2
        fi
        if [[ -n "${pure_kept}" ]]; then
          echo "Its FULL output is kept at:" >&2
          echo "  ${pure_kept}" >&2
          echo "(that directory keeps the last ${DIAGNOSTICS_KEEP}; older ones are deleted.)" >&2
        else
          echo "Its full output could NOT be kept (nothing could be written under ${DIAGNOSTICS_DIR})," >&2
          echo "so the lines above are all there is. Reproduce it with:" >&2
          echo "  xcodebuild -scheme OvertureCore -destination 'platform=macOS' test" >&2
        fi
      fi
      rm -f "${pure_output}"
    fi
  fi

  # #2600: and the LAST thing on screen is the complete list of what failed.
  #
  # A failed run reports its failures two different ways and reading the log for one of them
  # under-counts: Swift Testing prints "Expectation failed:" for an #expect, while a guard raising
  # Issue.record prints only "recorded an issue". On 2026-08-12 a run of #2417's branch was read by
  # searching for the first phrase, reported as two failures, and actually had eight; twenty minutes
  # of work followed from believing the branch was nearly green. xcodebuild's own list is the honest
  # answer and was already in the output, roughly forty thousand lines up a log nobody reads to the
  # end, which is why the cheap partial reading is the one anybody working at speed reaches for.
  #
  # Printed only when this run NAMED failing tests. A crash prints the heading with nothing under it
  # (#1006's whole tell), and "FAILING TESTS (0)" would be a count of a run that did not fail at all.
  local failing_reprint
  failing_reprint="$(failing_tests_report "${last_output}")"
  if [[ -n "${failing_reprint}" ]]; then
    echo >&2
    awk 'NR==1 {print "run-tests-locked.sh: " $0; next} {print}' <<< "${failing_reprint}" >&2
  fi

  # #1252: a test-host launch failure exits xcodebuild 0, so `test_exit_code` alone would let a dead run
  # escape as a pass (test-all.sh's `set -e` would sail past). A non-empty outcome is a crash or a real
  # failure; never propagate a 0 for it.
  if [[ -n "${outcome}" && "${test_exit_code}" -eq 0 ]]; then
    exit 1
  fi
  exit "${test_exit_code}"
}

# Allow this file to be sourced (e.g. by a test fixture) without running main, so
# stale_debug_test_host_pids can be exercised directly. Mirrors merge-when-green.sh's convention.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
