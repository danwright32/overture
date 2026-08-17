#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"

# #2193, #2232: the suite's own shape, reported by the run rather than counted by hand and written
# into a document that then drifts.
#
# Everything here is pure. Nothing runs xcodebuild, counts real files, or touches the repo; each
# function is handed the text it would have read.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./suite-stats.sh
source "${SCRIPT_DIR}/suite-stats.sh"
set +e

FAILURES=0

assert_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

# ---------------------------------------------------------------------------
# test_run_totals: the counts, taken from what the run actually executed
# ---------------------------------------------------------------------------
# A run of the combined scheme prints one "Test run with ..." line PER TARGET, so the totals are a
# sum, not the last line. Reading only the last one would report the hosted suite's 254 as the whole
# suite, which is the exact "a scoped run executed almost nothing" misreading these numbers exist to
# let someone catch.

# Swift Testing prefixes each line with a pass or fail mark, and the fixtures below carry them so
# they are byte-for-byte what xcodebuild really prints (L48). They are built from their UTF-8 bytes
# rather than typed literally: the pre-push style gate forbids those characters in source, and it is
# right to, since it cannot tell a line that USES one from a line that must quote one. An escape
# leaves the file holding no literal mark while the string still holds the real thing.
PASS_MARK="$(printf '\xe2\x9c\x94')"
FAIL_MARK="$(printf '\xe2\x9c\x98')"
STARTED_MARK="$(printf '\xe2\x97\x87')"

TWO_TARGET_RUN="${STARTED_MARK} Test run started.
${PASS_MARK} Test run with 5923 tests in 835 suites passed after 102.546 seconds.
${PASS_MARK} Test run with 254 tests in 43 suites passed after 4.322 seconds.
** TEST SUCCEEDED **"

assert_eq "both targets are added up, not just the last one" \
  "$(test_run_totals "${TWO_TARGET_RUN}")" \
  "6177 878 106.868"

assert_eq "a single-target run reports its own numbers" \
  "$(test_run_totals "${PASS_MARK} Test run with 5923 tests in 835 suites passed after 102.546 seconds.")" \
  "5923 835 102.546"

# The case that must not be silently reported as a healthy zero. A scoped run matching nothing prints
# TEST SUCCEEDED having executed nothing at all, and an empty report would look like the readout
# simply had nothing to say rather than like a run that did nothing.
assert_eq "a run that executed nothing yields nothing, not a zero" \
  "$(test_run_totals '** TEST SUCCEEDED **')" \
  ""

# A failing run still states its shape. A red suite is exactly when someone wants to know whether
# the count moved, and the pass/fail word is the only thing that differs in the line.
assert_eq "a failed run is counted the same way" \
  "$(test_run_totals "${FAIL_MARK} Test run with 5923 tests in 835 suites failed after 102.546 seconds with 3 issues.")" \
  "5923 835 102.546"

# #2317: Swift Testing writes the words SINGULAR when there is one of something, so a run of a single
# suite says "in 1 suite" and a run of a single test says "1 test". A parser that only knows the plural
# reads those runs as having executed nothing at all.
#
# Found by running a real scope through the wrapper: `-only-testing:OvertureTests/StoreSchemaGuardTests`
# printed "Test run with 10 tests in 1 suite passed" and was reported as a run that executed nothing,
# which is precisely the false alarm that teaches somebody to ignore this gate.
assert_eq "a run of one suite is counted, not read as nothing" \
  "$(test_run_totals "${PASS_MARK} Test run with 10 tests in 1 suite passed after 0.029 seconds.")" \
  "10 1 0.029"

assert_eq "a run of one test is counted too" \
  "$(test_run_totals "${PASS_MARK} Test run with 1 test in 1 suite passed after 0.004 seconds.")" \
  "1 1 0.004"

# And the readout says it in words, rather than "1 suites", now that a scoped run of a single suite is
# something this wrapper can be asked for.
assert_eq "the readout counts one suite in the singular" \
  "$(format_suite_report "10 1 0.029" "1.70" "1176" "6219")" \
  "Suite shape: 10 tests in 1 suite, 0.029s. Test Swift to app Swift 1.70 to 1. Source-text guards are 1176 of 6219 test declarations."

assert_eq "and one test in the singular too" \
  "$(format_suite_report "1 1 0.004" "1.70" "1176" "6219")" \
  "Suite shape: 1 test in 1 suite, 0.004s. Test Swift to app Swift 1.70 to 1. Source-text guards are 1176 of 6219 test declarations."

# ---------------------------------------------------------------------------
# line_ratio: test Swift against app Swift
# ---------------------------------------------------------------------------

assert_eq "the ratio is test lines to app lines, to two places" \
  "$(line_ratio 57308 95247)" \
  "1.66"

assert_eq "an equal split reads as 1.00 rather than as an integer" \
  "$(line_ratio 1000 1000)" \
  "1.00"

# Never a division by zero, and never a made-up number standing in for one. An app with no source is
# a broken count, not a ratio of infinity.
assert_eq "no app source means no ratio rather than a fabricated one" \
  "$(line_ratio 0 95247)" \
  "unknown"

# ---------------------------------------------------------------------------
# format_suite_report: what gets printed
# ---------------------------------------------------------------------------
# The report must never state a number it did not measure. When the run printed no totals, it says
# so in words instead of printing zeros, because "0 tests" and "I could not tell" are different
# facts and only one of them is alarming.

assert_eq "a full report states every measured number" \
  "$(format_suite_report "6177 878 106.868" "1.66" "1204" "5980")" \
  "Suite shape: 6177 tests in 878 suites, 106.868s. Test Swift to app Swift 1.66 to 1. Source-text guards are 1204 of 5980 test declarations."

assert_eq "an unreadable run says so instead of reporting zeros" \
  "$(format_suite_report "" "1.66" "1204" "5980")" \
  "Suite shape: could not read the test totals from this run. Test Swift to app Swift 1.66 to 1. Source-text guards are 1204 of 5980 test declarations."

assert_eq "an unreadable ratio is named too, not quietly dropped" \
  "$(format_suite_report "6177 878 106.868" "unknown" "1204" "5980")" \
  "Suite shape: 6177 tests in 878 suites, 106.868s. Test Swift to app Swift could not be measured. Source-text guards are 1204 of 5980 test declarations."

# The guard share is deliberately quoted against test DECLARATIONS, not against the run's test count,
# even though the two happen to agree exactly today. Nothing holds them equal, so a share formed by
# dividing one by the other would be a percentage of nothing real the moment they part (L63).
assert_eq "no declarations counted means no share claimed" \
  "$(format_suite_report "6177 878 106.868" "1.66" "0" "0")" \
  "Suite shape: 6177 tests in 878 suites, 106.868s. Test Swift to app Swift 1.66 to 1. Source-text guard share could not be measured."

echo
# ---------------------------------------------------------------------------
# failing_test_names / failing_tests_report: the list, reprinted (#2600)
# ---------------------------------------------------------------------------
# A failed run reports its failures two different ways, and reading the log for one of them
# UNDER-COUNTS. Swift Testing prints "Expectation failed:" for an #expect, but a guard raising
# Issue.record prints only "recorded an issue". On 2026-08-12 a run of #2417's branch was read by
# searching for the first phrase, reported as two failures, and actually had eight. Twenty minutes
# of work followed from believing the branch was nearly green.
#
# xcodebuild's own "Failing tests:" block is the honest answer and is already in the output, roughly
# forty thousand lines down a log nobody reads to the end. So the run reprints it at the very end.

# Both kinds in one log, which is the case the cheap partial reading gets wrong. Named with the tab
# xcodebuild indents them by, so the parsing under test is the real shape.
MIXED_FAILURE_OUTPUT="Test aThingWorks() recorded an issue at Foo.swift:12:5: Expectation failed: 1 == 2
Test aGuardHolds() recorded an issue at Bar.swift:44:3: the venue guard did not fire
Failing tests:
	OvertureTests.FooTests.aThingWorks()
	OvertureTests.BarTests.aGuardHolds()

** TEST FAILED **"

assert_eq "every test xcodebuild named is read out of the block, trimmed" \
  "$(failing_test_names "${MIXED_FAILURE_OUTPUT}")" \
  "OvertureTests.FooTests.aThingWorks()
OvertureTests.BarTests.aGuardHolds()"

# THE case, stated as the difference between the two readings. A log in which NOT ONE line says
# "Expectation failed:" still holds two real failures, and the phrase-counting habit reports zero.
ISSUE_RECORD_ONLY_OUTPUT="Test aGuardHolds() recorded an issue at Bar.swift:44:3: the venue guard did not fire
Test anotherGuardHolds() recorded an issue at Baz.swift:9:1: the pill count did not match its rows
Failing tests:
	OvertureTests.BarTests.aGuardHolds()
	OvertureTests.BazTests.anotherGuardHolds()

** TEST FAILED **"

assert_eq "the phrase-counting reading of an Issue.record-only run really does find nothing" \
  "$(grep -c 'Expectation failed:' <<< "${ISSUE_RECORD_ONLY_OUTPUT}")" \
  "0"

assert_eq "while the block names both of them" \
  "$(failing_test_names "${ISSUE_RECORD_ONLY_OUTPUT}" | grep -c .)" \
  "2"

assert_eq "the reprint leads with the count and then names each test" \
  "$(failing_tests_report "${ISSUE_RECORD_ONLY_OUTPUT}")" \
  "FAILING TESTS (2), reprinted so the list is the last thing on screen:
  OvertureTests.BarTests.aGuardHolds()
  OvertureTests.BazTests.anotherGuardHolds()"

assert_eq "one failure is counted in the singular" \
  "$(failing_tests_report "Failing tests:
	OvertureTests.FooTests.aThingWorks()
** TEST FAILED **")" \
  "FAILING TEST (1), reprinted so the list is the last thing on screen:
  OvertureTests.FooTests.aThingWorks()"

# A crashed run prints the heading with NOTHING under it, which is #1006's whole tell. It must not
# come back as "FAILING TESTS (0)": a run that named no failing test did not fail, it died, and the
# crash path says so in its own words.
assert_eq "a crash, which names the heading and nothing under it, reprints nothing" \
  "$(failing_tests_report "Test run with 1574 tests in 229 suites passed after 10.851 seconds.
Failing tests:
** TEST FAILED **")" \
  ""

assert_eq "and a passing run has nothing to reprint" \
  "$(failing_tests_report "Test run with 6177 tests in 878 suites passed after 106.868 seconds.
** TEST SUCCEEDED **")" \
  ""

echo
# ---------------------------------------------------------------------------
# test_run_restarted: a remainder is not the run (#2821)
# ---------------------------------------------------------------------------
# Measured 2026-08-16 while re-checking #2808's mutations: mutated code made a test exceed its one
# minute .timeLimit, which kills the test process. xcodebuild restarted and ran the remainder, and
# the final line read "Suite shape: 12 tests in 2 suites, 0.009s" for a run that had really started
# 70 tests across 8 suites.
#
# AGENTS.md names that line as THE reference for "did this run execute the whole suite?", written
# precisely because a scoped run matching almost nothing prints success. After a restart the line
# reports a small number for a run that was BROKEN rather than small, so the reading it exists to
# support is exactly the reading it gets wrong.
#
# It refuses to print a shape rather than summing across the attempts, because a total assembled
# across a crash is its own kind of claim: xcodebuild says the summary "will include totals from
# previous launches" and the measurement above says it did not.
RESTARTED_OUTPUT="Test Suite 'All tests' started
Restarting after unexpected exit, crash, or test timeout in OvertureTests.PrepTests/aCheckStartedWhileAPrepIsLiveIsStillFollowed(); summary will include totals from previous launches.
Test run with 12 tests in 2 suites failed after 0.009 seconds with 1 issue.
** TEST FAILED **"

assert_eq "a run xcodebuild relaunched says so" \
  "$(test_run_restarted "${RESTARTED_OUTPUT}")" \
  "restarted"

assert_eq "an ordinary run did not restart" \
  "$(test_run_restarted "${TWO_TARGET_RUN}")" \
  ""

# The totals are still READ, unchanged: the parser is not the thing that was wrong, the reporting of
# its answer as the whole run was.
assert_eq "the parser still reads the remainder's own numbers" \
  "$(test_run_totals "${RESTARTED_OUTPUT}")" \
  "12 2 0.009"

assert_eq "a restarted run refuses to state a shape, and names the restart" \
  "$(format_suite_report "12 2 0.009" "1.66" "1204" "5980" "restarted")" \
  "Suite shape: NOT REPORTED. The test process RESTARTED during this run (xcodebuild relaunched it after an unexpected exit, crash or test timeout), so the totals it printed cover only what ran AFTER the last restart, not this whole run. Nothing here can be read as the size of the suite. Re-run it. See #2821."

# And it must not quietly keep the plausible-looking number beside the warning, which is what makes
# a post-restart remainder readable as a real measurement in the first place.
assert_eq "the refusal states no count at all" \
  "$(format_suite_report "12 2 0.009" "1.66" "1204" "5980" "restarted" | grep -c '12 tests')" \
  "0"

assert_eq "an ordinary run is unaffected by the new argument being absent" \
  "$(format_suite_report "6177 878 106.868" "1.66" "1204" "5980")" \
  "Suite shape: 6177 tests in 878 suites, 106.868s. Test Swift to app Swift 1.66 to 1. Source-text guards are 1204 of 5980 test declarations."

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All suite-stats.sh fixtures passed."
  exit 0
fi
echo "${FAILURES} suite-stats.sh fixture(s) failed." >&2
exit 1
