#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/shell-assertions.sh"

# Pure-function coverage for check-health-recorder-drift.sh's health_recorder_funcs (#1073). The real
# check scans the two scout ingest Swift files; this fixture drives the same detector against throwaway
# Swift-like text so it runs anywhere including CI, and proves the guard both PASSES the consolidated
# single-recorder shape and FAILS the reintroduced near-copy it exists to catch.
#
# The load-bearing case is `red`: two functions each directly writing the health-field cluster is the
# exact #987/#1001/#1005 shape (one silently stops writing a field and drifts). If the detector stops
# flagging that, this fixture goes red, which is the mutation this guard must survive.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./check-health-recorder-drift.sh
source "${SCRIPT_DIR}/check-health-recorder-drift.sh"
# check-health-recorder-drift.sh's own `set -euo pipefail` is now active. Turn errexit off so one
# failing assertion doesn't abort the rest of the run.
set +e

FAILURES=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected to contain: ${needle}"
    echo "  actual: ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

# Runs health_recorder_funcs, capturing its printed names in OUT and their count in COUNT.
run_detect() {
  OUT="$(health_recorder_funcs "$1")"
  if [[ -z "${OUT}" ]]; then
    COUNT=0
  else
    COUNT="$(printf '%s\n' "${OUT}" | grep -c '^')"
  fi
}

# GREEN: the consolidated shape. Exactly one function directly writes the cluster (recordPartialCheck,
# which cannot delegate); the other two delegate to recordSuccessfulRead or only READ the fields. None
# of the delegating/reading forms may count as a recorder.
GREEN='
    private static func recordPartialCheck(on source: WatchedSource, events: Int) {
        source.lastReadableCount = events
        source.lastUnreadableCount = unreadable
        source.lastUnreadableTitleCount = titleUnreadable
        source.hadPlacedBeforeLastRun = source.hasEverPlaced
        source.lastPlacedCount = placed
    }

    private static func recordSuccess(on source: WatchedSource, events: Int) {
        source.recordSuccessfulRead(events: events, unreadable: unreadable, placed: placed)
    }

    private static func check(_ source: WatchedSource) -> Int {
        // reads and comparisons must not count as writes
        let base = source.baselineFeedCount
        let streak = source?.degradedStreak ?? 0
        return source.successfulCheckCount
    }
'
run_detect "${GREEN}"
assert_eq "green: exactly one direct recorder detected" "1" "${COUNT}"
assert_eq "green: the one recorder is recordPartialCheck" "recordPartialCheck" "${OUT}"

# RED (the mutation this guard exists to catch): recordSuccess is inlined into a SECOND near-copy that
# directly writes the cluster instead of delegating. Now two functions can drift.
RED='
    private static func recordPartialCheck(on source: WatchedSource, events: Int) {
        source.lastReadableCount = events
        source.lastUnreadableCount = unreadable
        source.lastUnreadableTitleCount = titleUnreadable
        source.hadPlacedBeforeLastRun = source.hasEverPlaced
        source.lastPlacedCount = placed
    }

    private static func recordSuccess(on source: WatchedSource, events: Int) {
        source.lastReadableCount = events
        source.lastUnreadableCount = unreadable
        source.baselineFeedCount = updated.baseline
        source.degradedStreak = updated.degradedStreak
        source.successfulCheckCount += 1
    }
'
run_detect "${RED}"
assert_eq "red: two direct recorders detected" "2" "${COUNT}"
assert_contains "red: names recordPartialCheck" "${OUT}" "recordPartialCheck"
assert_contains "red: names recordSuccess" "${OUT}" "recordSuccess"

# Comments that NAME cluster fields to explain what a function does NOT write must not count as writes
# (recordPartialCheck's real docblock does exactly this).
COMMENTED='
    private static func recordPartialCheck(on source: WatchedSource, events: Int) {
        // Deliberately does NOT touch baselineFeedCount, degradedStreak or successfulCheckCount.
        // A future maintainer might even write source.baselineFeedCount = 0 in prose like this.
        source.lastReadableCount = events
        source.lastUnreadableCount = unreadable
        source.lastUnreadableTitleCount = titleUnreadable
    }
'
run_detect "${COMMENTED}"
assert_eq "commented: field names in comments do not count" "1" "${COUNT}"
assert_eq "commented: still just recordPartialCheck" "recordPartialCheck" "${OUT}"

# Below-threshold: a helper that writes only two cluster fields is not a near-copy recorder.
SMALL='
    private static func touchTwo(on source: WatchedSource) {
        source.lastReadableCount = events
        source.lastUnreadableCount = unreadable
    }
'
run_detect "${SMALL}"
assert_eq "small: a two-field helper is below threshold" "0" "${COUNT}"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "check-health-recorder-drift.test.sh: all assertions passed"
  exit 0
else
  echo "check-health-recorder-drift.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
