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
  [[ "${code}" -eq 0 ]] && return

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
  if [[ "$(run_outcome "$(cat "${output_file}")" "${test_exit_code}")" == "crashed" ]]; then
    echo >&2
    echo "run-tests-locked.sh: the test run CRASHED. It did not fail." >&2
    echo "xcodebuild reported failure and named no failing test, so no test failed: the test host died mid-run." >&2
    echo "Any count printed above (\"Test run with N tests ... passed\") counts only what ran BEFORE it died, and is not a pass." >&2
    echo "Usual cause is something killing the host, e.g. an overlapping run on this Mac. Rerun it; if it passes, the code was never the problem. See #1006." >&2
  fi
  rm -f "${output_file}"

  exit "${test_exit_code}"
}

# Allow this file to be sourced (e.g. by a test fixture) without running main, so
# stale_debug_test_host_pids can be exercised directly. Mirrors merge-when-green.sh's convention.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
