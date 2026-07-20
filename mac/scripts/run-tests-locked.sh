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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Given `ps -eo pid=,command=`-style output (one process per line: PID then its full command),
# returns the PIDs of any resident Debug-configuration Overture.app test host (#632): the one
# xcodebuild test boots at .../DerivedData/*/Build/Products/Debug/Overture.app/Contents/MacOS/Overture.
# A Release build (e.g. /Applications/Overture.app, from build-install.sh --launch) never matches,
# so it's never touched. Pure text match, so it's testable without touching real system state.
stale_debug_test_host_pids() {
  local ps_output="$1"
  echo "${ps_output}" | grep -F '/DerivedData/' | grep -F '/Build/Products/Debug/Overture.app/Contents/MacOS/Overture' | awk '{print $1}'
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

# run_outcome <xcodebuild output> <exit code>. "crashed", "failed", or "" for a pass.
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
    echo "crashed"
    return
  fi

  # Every line xcodebuild lists between "Failing tests:" and its verdict is a named failure.
  local named
  named="$(awk '/^Failing tests:/{f=1;next} /^\*\* TEST/{f=0} f' <<< "${output}" | grep -c '[^[:space:]]' || true)"
  if [[ "${named}" -gt 0 ]]; then
    echo "failed"
  else
    echo "crashed"
  fi
}

main() {
  command -v flock >/dev/null || { echo "flock not found; install it with: brew install flock" >&2; exit 1; }

  cd "${MAC_DIR}"

  # #1257: prevent, don't just detect (#1252). A Debug Overture run-debug.sh launched from mac/build holds
  # the single-instance lock, so the test host cannot launch and the whole run dies AFTER a full build. Stop
  # here, before building, with the one instruction that fixes it. A stale DerivedData test host from a prior
  # aborted run would block the same way, but it is the runner's OWN spawn and safe to clear, so clear it
  # rather than nag; the mac/build instance is Dan's and is never auto-killed.
  local stale_pid
  for stale_pid in $(stale_debug_test_host_pids "$(ps -eo pid=,command=)"); do
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

  local test_exit_code=0
  local output_file
  output_file="$(mktemp)"
  # tee, so the run still streams live: a suite that only prints at the end looks hung (#1006's
  # investigation was slow enough without waiting blind).
  flock "${LOCK_FILE}" xcodebuild -scheme Overture -destination 'platform=macOS' test \
    2>&1 | tee "${output_file}" || true
  test_exit_code="${PIPESTATUS[0]}"

  local pid
  for pid in $(stale_debug_test_host_pids "$(ps -eo pid=,command=)"); do
    kill "${pid}" 2>/dev/null || true
  done

  # #1006: say WHICH kind of red this is, in the words a person needs. "** TEST FAILED **" with
  # nothing named means the process died, not that a test failed, and reading it as a test
  # failure sends whoever sees it hunting for a bug that does not exist.
  local outcome
  outcome="$(run_outcome "$(cat "${output_file}")" "${test_exit_code}")"
  if [[ "${outcome}" == "crashed" ]]; then
    echo >&2
    echo "run-tests-locked.sh: the test run CRASHED. It did not pass and it did not fail: the run died." >&2
    echo "Usual causes: the test host could not launch (a running Debug app holding the single-instance lock)," >&2
    echo "or something killed the host mid-run (an overlapping run on this Mac). Any count printed above is not a pass." >&2
    echo "Quit any running Debug Overture, then rerun it; if it passes, the code was never the problem. See #1006/#1252." >&2
  fi
  rm -f "${output_file}"

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
