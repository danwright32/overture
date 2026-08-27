#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501).
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts/lib/shell-assertions.sh"

# Coverage for mac/scripts/lib/hosted-suite-stamp.sh (#1995): when the tests that render a real SwiftUI
# view last actually passed on this machine.
#
# #1967 split the suite so a launch fault costs the hosted tests instead of all of them, which is the
# point. The gap it opens is that nothing recorded WHEN those tests last ran, so a host broken across a
# stretch of UI work leaves the screens unverified for as long as that lasts, silently, and an unrun test
# and a passing test look identical from outside (L98).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./hosted-suite-stamp.sh
source "${SCRIPT_DIR}/hosted-suite-stamp.sh"

# The marks xcodebuild really prints, built from their UTF-8 bytes rather than typed. The pre-push style
# gate blocks a new line carrying one, and it cannot tell a line that USES the character from a line that
# must QUOTE it, which is the gate working correctly. `mac/scripts/lib/suite-stats.test.sh` builds them the
# same way for the same reason (#2193). The fixture wants the REAL output shape, not a cleaned-up one.
PASS_MARK="$(printf '\xe2\x9c\x94')"
STARTED_MARK="$(printf '\xe2\x97\x87')"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
FAILURES=0

# --- the names come from the directory, never from a list written here -------------------------------
mkdir -p "${WORK}/HostedTests"
cat > "${WORK}/HostedTests/RowTests.swift" <<'SWIFT'
@Suite("The reachability badge on a card (#1145)")
struct ProspectRowViewReachabilityTests {}
SWIFT
cat > "${WORK}/HostedTests/SheetTests.swift" <<'SWIFT'
@MainActor
@Suite("The send sheet's editable body (#2086)")
struct SendSheetEditableBodyTests {}

// A suite with no display name contributes nothing, which costs only a run where it is the only one
// reporting. Stated rather than left to be discovered.
@Suite
struct SomethingUnnamedTests {}
SWIFT

NAMES="$(hosted_suite_names "${WORK}/HostedTests")"
assert_equals "both named suites are read, in sorted order" \
  "The reachability badge on a card (#1145)
The send sheet's editable body (#2086)" "${NAMES}"

assert_empty "a directory that is not there reads as no names, not as an error" \
  "$(hosted_suite_names "${WORK}/nowhere")"

# --- a run that verified the screens, and the three that did not -------------------------------------
#
# Driven with the run's output as TEXT, through `$(cat ...)`, because that is what `run-tests-locked.sh`
# holds and hands to every reporting helper beside this one. The first version passed the PATH, which the
# library happened to accept, and the mismatch shipped: handed text by the real caller its `[ -f ]` guard
# was false, and a full run that had just passed all 49 hosted suites printed "NOT VERIFIED by this run,
# and no run on this clone has ever verified them". A test whose only outside dependency is a stub of its
# own shape can only confirm the shape it assumed (L52).
PASSED="${WORK}/passed.log"
cat > "${PASSED}" <<'OUT'
${PASS_MARK} Suite "The reachability badge on a card (#1145)" passed after 0.018 seconds.
${PASS_MARK} Test run with 296 tests in 49 suites passed after 4.9 seconds.
OUT
assert_equals "a run naming a hosted suite as passed has verified the screens" \
  "The reachability badge on a card (#1145)" "$(hosted_suites_ran "$(cat "${PASSED}")" "${NAMES}")"

# The case a bundle-count proxy cannot tell apart: a scoped PURE run reports one bundle and names no
# hosted suite at all.
SCOPED="${WORK}/scoped.log"
cat > "${SCOPED}" <<'OUT'
${PASS_MARK} Suite "Reachability badge rules (#1145)" passed after 0.002 seconds.
${PASS_MARK} Test run with 12 tests in 1 suite passed after 0.1 seconds.
OUT
assert_empty "a scoped pure run has verified nothing about the screens" \
  "$(hosted_suites_ran "$(cat "${SCOPED}")" "${NAMES}")"

# The case that matters most, and the reason the needle is "passed" rather than the suite name alone: a
# run that STARTED the hosted bundle and died inside it names those suites exactly as a passing run does.
CRASHED="${WORK}/crashed.log"
cat > "${CRASHED}" <<'OUT'
${STARTED_MARK} Suite "The reachability badge on a card (#1145)" started.
Restarting after unexpected exit, crash, or test timeout
OUT
assert_empty "a run that started the hosted bundle and died has verified nothing" \
  "$(hosted_suites_ran "$(cat "${CRASHED}")" "${NAMES}")"

assert_empty "and with no names to look for, nothing is claimed either way" \
  "$(hosted_suites_ran "$(cat "${PASSED}")" "")"

# --- the record moves only when a run really verified them --------------------------------------------
#
# The whole mechanism. Stamping every run would move the date forward while the host stayed broken, the
# age would always read zero, and the gap would be invisible behind a date that looks like a measurement.
assert_equals "a verifying run stamps today" \
  "screens=2026-08-27" "$(hosted_stamp_update "a suite" "2026-08-27" "screens=2026-08-01")"
assert_equals "a run that verified nothing leaves the record exactly as it was" \
  "screens=2026-08-01" "$(hosted_stamp_update "" "2026-08-27" "screens=2026-08-01")"
assert_empty "and leaves an absent record absent rather than inventing one" \
  "$(hosted_stamp_update "" "2026-08-27" "")"

assert_equals "the recorded date is read back" "2026-08-01" "$(hosted_stamp_date "screens=2026-08-01")"
assert_empty "an empty record has no date" "$(hosted_stamp_date "")"
assert_empty "and neither does a record in a shape this does not know" "$(hosted_stamp_date "junk")"

assert_equals "the age is whole days between the two" "26" "$(hosted_stamp_age_days "2026-08-01" "2026-08-27")"
assert_empty "an unparseable date reports no age rather than a wrong one" \
  "$(hosted_stamp_age_days "not-a-date" "2026-08-27")"

# --- four states, and only one of them is good --------------------------------------------------------
VERIFIED_LINE="$(hosted_freshness_line "a suite" "2026-08-01" "2026-08-27" "${NAMES}")"
assert_contains "a verifying run says so" "${VERIFIED_LINE}" "verified by this run"
assert_not_contains "and does not also warn" "${VERIFIED_LINE}" "NOT VERIFIED"

STALE_LINE="$(hosted_freshness_line "" "2026-08-01" "2026-08-27" "${NAMES}")"
assert_contains "a run that skipped them says NOT VERIFIED" "${STALE_LINE}" "NOT VERIFIED by this run"
assert_contains "and names the day they last passed" "${STALE_LINE}" "2026-08-01"
assert_contains "and how long ago that was, which is the half worth acting on" "${STALE_LINE}" "26 days ago"

NEVER_LINE="$(hosted_freshness_line "" "" "2026-08-27" "${NAMES}")"
assert_contains "never having verified them is its own sentence" "${NEVER_LINE}" "has ever verified them"
assert_not_contains "and does not print a date it does not have" "${NEVER_LINE}" "last passed on"

# UNMEASURED is the state that must never be folded into NOT VERIFIED: one says the screens went
# unchecked, the other says this script could not tell, and they call for different actions (L11).
UNMEASURED_LINE="$(hosted_freshness_line "" "2026-08-01" "2026-08-27" "")"
assert_contains "no suite names at all is UNMEASURED" "${UNMEASURED_LINE}" "UNMEASURED"
assert_not_contains "and is never reported as the screens having gone unverified" \
  "${UNMEASURED_LINE}" "NOT VERIFIED"

# --- the runner really asks, and really writes ---------------------------------------------------------
#
# The library being right is worth nothing if the wrapper does not call it (L3). Asserted on the runner's
# source because the behaviour needs a real xcodebuild run to exercise.
RUNNER="$(cat "${SCRIPT_DIR}/../run-tests-locked.sh")"
assert_contains "the runner sources the library" "${RUNNER}" "lib/hosted-suite-stamp.sh"
assert_contains "it derives the names from the hosted directory" \
  "${RUNNER}" 'hosted_suite_names "${MAC_DIR}/OvertureHostedTests"'
assert_contains "it asks whether this run verified them" "${RUNNER}" "hosted_suites_ran"
assert_contains "it prints where they stand" "${RUNNER}" "hosted_freshness_line"
assert_contains "and the record is overridable, so a fixture cannot write into the live tree" \
  "${RUNNER}" "OVERTURE_HOSTED_SUITE_RECORD"
# The mismatch that shipped once: the runner holds the output as TEXT and hands the same `last_output`
# to every reporting helper. Asserted so a future signature change cannot quietly reintroduce a reader
# that is handed something it does not understand and answers "nothing" (L52, L98).
assert_contains "and hands it the same run output its siblings get" \
  "${RUNNER}" 'hosted_suites_ran "${last_output}"'
assert_contains "which is the same value the live-store report is given" \
  "${RUNNER}" 'live_corpus_report "${last_output}"' 

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "hosted-suite-stamp.test.sh: all assertions passed"
  exit 0
else
  echo "hosted-suite-stamp.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
