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

main() {
  command -v flock >/dev/null || { echo "flock not found; install it with: brew install flock" >&2; exit 1; }

  cd "${MAC_DIR}"
  local test_exit_code=0
  flock "${LOCK_FILE}" xcodebuild -scheme Overture -destination 'platform=macOS' test || test_exit_code=$?

  local pid
  for pid in $(stale_debug_test_host_pids "$(ps -eo pid=,command=)"); do
    kill "${pid}" 2>/dev/null || true
  done

  exit "${test_exit_code}"
}

# Allow this file to be sourced (e.g. by a test fixture) without running main, so
# stale_debug_test_host_pids can be exercised directly. Mirrors merge-when-green.sh's convention.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
