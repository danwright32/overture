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
# test_run_totals: the PARALLEL format (#3233)
# ---------------------------------------------------------------------------
# A run under `-parallel-testing-enabled YES` prints NO "Test run with ..." summary at all. Every
# test is reported on its own line instead:
#
#   Test case 'Suite/test()' passed on 'My Mac - xctest (63822)' (0.013 seconds)
#
# Measured 2026-08-29, the audit experiment behind milestone 60. Nothing here could read that, so
# the run ended with "Suite shape: could not read the test totals from this run", and because the
# executed count is what the short-run gate compares against a baseline, THE GATE COULD NOT FIRE.
# That run executed 4,875 of 8,595 tests, one of its two workers printed 58 lines and its whole
# share never appeared, no crash line was printed anywhere, and the only thing on screen was a list
# of 12 failing tests offered as though it were the whole story (L98, L11).
#
# The fixture beside this file is that run's own output, trimmed. Trimmed in VOLUME only: every line
# in it is a real line from the real log, and the shapes that made the incident hard to read are all
# kept, because they are what a parser has to survive:
#
#   * BOTH workers, named by different pids, plus the app host's own destination;
#   * a `skipped` verb as well as `passed` and `failed`;
#   * a parameterised test printing one line PER CASE under one name;
#   * a retried test printing its line more than once;
#   * one line CORRUPTED by two workers writing at the same moment, which is where the run's own
#     elapsed reading ended up glued onto the end of a half-written test case line. That is not a
#     curiosity: it is why the readable count in the full log is 4,874 against the xcresult's 4,875.
#
# The full 839KB log is kept at ~/.overture-mac-test-diagnostics/parallel-experiment-20260829.log.
PARALLEL_LOG="$(cat "${SCRIPT_DIR}/fixtures/parallel-run-20260829.log")"

# The count is what the gate needs, so it is the first thing asserted. 26 distinct tests across 12
# suites is what this trimmed log holds; the full one held 4,874 against a baseline of 8,595.
assert_eq "a parallel run's totals are read rather than reported as unreadable" \
  "$(test_run_totals "${PARALLEL_LOG}")" \
  "26 12 95.447"

# Counted by NAME, not by line. 34 lines carry a verb in this fixture and 26 distinct tests produced
# them: a parameterised test prints one line per case and a retried one prints its line again, so a
# line count would report more tests than ran and, being the larger number, would report a truncated
# run as a longer one than it was. That is the direction this gate must never be wrong in.
assert_eq "a repeated line is one test, not two" \
  "$(test_run_totals "${PARALLEL_LOG}" | awk '{print $1}')" \
  "26"

# The DURATION is the one number in this format that cannot be taken from the test lines. Each of
# them ends in "(N seconds)" and N is elapsed since that WORKER began, not what the test cost: a
# one-line boolean in the real log reported 64.4 seconds. Summing them here would say 338.423s for a
# run that took 95.447, and every one of those numbers looks perfectly plausible.
assert_eq "the duration comes from the run's own elapsed line, never the sum of the test lines" \
  "$(test_run_totals "${PARALLEL_LOG}" | awk '{print $3}')" \
  "95.447"

# The elapsed reading and the counts are separate measurements, so one being unreadable must not
# destroy the other. Losing that line is not hypothetical: in the real log it survived only because
# it was glued onto a test case line, and the next collision could as easily have taken it. The
# counts still gate the run; the duration says it was not measured rather than inventing a zero.
PARALLEL_NO_ELAPSED="$(grep -av 'elapsed -- Testing started completed' <<< "${PARALLEL_LOG}")"
assert_eq "a lost elapsed line leaves the counts intact and the duration unclaimed" \
  "$(test_run_totals "${PARALLEL_NO_ELAPSED}")" \
  "26 12 unknown"

assert_eq "and the readout names the missing duration instead of printing a number" \
  "$(format_suite_report "26 12 unknown" "1.90" "1176" "6219")" \
  "Suite shape: 26 tests in 12 suites, duration not reported by this run. Test Swift to app Swift 1.90 to 1. Source-text guards are 1176 of 6219 test declarations."

# A parallel run that started nothing is still a run that executed nothing, and must not come back
# as a zero. Same rule as the serial format above: no reading is not a reading of none.
assert_eq "a parallel run with no test lines yields nothing, not a zero" \
  "$(test_run_totals "Testing started
95.447 elapsed -- Testing started completed.
** TEST SUCCEEDED **")" \
  ""

# The test that used to sit here asserted that a serial summary is PREFERRED over counting lines, and
# it is deleted rather than adjusted because #3266 reversed that rule: a log carrying both is a MIXED
# run, where the summary covers only the serial testable and the lines only the parallel one, so the two
# are summed. A test defending a reversed decision is not stale coverage, it is a guard for the
# behaviour that was rejected (L252). What replaces it is the mixed-run block below, driven by a real
# trimmed log rather than by the two hand-written lines that one used.

# The failing list is read from xcodebuild's own block either way, so a parallel run's failures are
# named exactly as a serial run's are. Worth asserting rather than assuming: this block is what the
# incident's verdict was built from, and its being right is what made the missing count invisible.
assert_eq "a parallel run's failing tests are still named" \
  "$(failing_test_names "${PARALLEL_LOG}" | grep -c .)" \
  "12"

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

# ---------------------------------------------------------------------------
# live_corpus_report: whether the live store invariants measured anything (#2991)
# ---------------------------------------------------------------------------
# `ReplyInvariantsLiveStoreTests` prints a corpus line every run saying how many rows each of its
# #3165: the number the readout is measured by is the WRITER-HELD count, not the still-open one. The open
# count empties whenever Dan is up to date, and it read zero for as long as this clone had recorded, so the
# readout reported a rule as dormant when the truth was that the rule had been asked a question its corpus
# could not hold. The record's key was renamed with it, because a key named `open` counting something else
# is how one word comes to name two units (L118); no history is lost, since the old count was zero on every
# machine that ever wrote the file, so no `open=` line exists anywhere to inherit.
# invariants could examine. Measured 2026-08-19 it read `0 with a reply still open, 0 reached-out rows
# in play`, so both invariants passed having asserted nothing about anything, and the only thing
# separating that from a clean bill of health was a printed line in a test log nobody is scheduled to
# read. That is L182 exactly: a count driven to zero stops being read as a measurement and starts
# being read as proof the thing cannot occur.
#
# So the state is stated in the readout AGENTS.md names as THE reference line for a finished run, in
# three states kept apart, because an unmeasured check and a passed one look identical from silence
# (L11).

CORPUS_LIVE="LIVE STORE CORPUS: 936 shows, 4 replied rows, 3 with a reply still open, 3 whose writer a contact holds, 5 reached-out rows in play. A zero here means the invariants in this suite ran over nothing."
CORPUS_DORMANT="LIVE STORE CORPUS: 936 shows, 4 replied rows, 0 with a reply still open, 0 whose writer a contact holds, 0 reached-out rows in play. A zero here means the invariants in this suite ran over nothing."
CORPUS_HALF="LIVE STORE CORPUS: 936 shows, 4 replied rows, 0 with a reply still open, 0 whose writer a contact holds, 5 reached-out rows in play. A zero here means the invariants in this suite ran over nothing."

# The clock and the record are PASSED IN, never read inside, so a test can pin both. This repo passes
# `now` explicitly everywhere for that reason, and a duration read off a hidden clock is one no test
# can hold still (L130).
TODAY="2026-08-23"
SEEN_BOTH="writer=2026-06-14
reached=2026-08-19"
SEEN_NEITHER=""

assert_eq "a corpus with rows in it says what each invariant measured" \
  "$(live_corpus_report "${CORPUS_LIVE}" "${TODAY}" "${SEEN_BOTH}")" \
  "Live store invariants: measuring, over 3 rows the writer-resolution rule can judge and 5 reached-out rows in play."

# #2991 asked for the DURATION, not only the state. "Both measured nothing today" is much weaker than
# "neither has measured anything since June": only the second says whether to care, and the whole
# defect is a zero that stops being read as a measurement (L182).
assert_eq "a dormant pair says how long each has been asleep" \
  "$(live_corpus_report "${CORPUS_DORMANT}" "${TODAY}" "${SEEN_BOTH}")" \
  "Live store invariants: DORMANT. The writer-resolution invariant has measured nothing since 2026-06-14 (70 days), the reached-out one since 2026-08-19 (4 days), so both passed having asserted nothing about Dan's real data (#2991, L182)."

# A clone with no record yet must say THAT, not guess a date and not fall silent. An unrecorded
# duration and a short one are different facts (L11).
assert_eq "a dormant pair with nothing recorded says so rather than inventing a date" \
  "$(live_corpus_report "${CORPUS_DORMANT}" "${TODAY}" "${SEEN_NEITHER}")" \
  "Live store invariants: DORMANT. The writer-resolution invariant has measured nothing for as long as this clone has recorded, the reached-out one for as long as this clone has recorded, so both passed having asserted nothing about Dan's real data (#2991, L182)."

# Half dormant is its own state and names WHICH half, because one invariant still having teeth is not
# the same fact as neither having any, and a message covering both would be true of neither.
assert_eq "one dormant invariant is named, with its own duration" \
  "$(live_corpus_report "${CORPUS_HALF}" "${TODAY}" "${SEEN_BOTH}")" \
  "Live store invariants: PARTLY DORMANT. The writer-resolution invariant has measured nothing since 2026-06-14 (70 days); the reached-out one measured 5 this run (#2991, L182)."

# The state that must never read as clean: no corpus line at all. That is what a scoped run produces,
# and what a rename of the test would produce, and the emptiest possible failure must not look like
# the cleanest possible pass (L98).
assert_eq "no corpus line at all is unmeasured, never clean" \
  "$(live_corpus_report "" "${TODAY}" "${SEEN_BOTH}")" \
  "Live store invariants: NOT REPORTED. This run printed no corpus line, so whether they measured anything is unknown; a scoped run does not include them."

assert_eq "a run whose output simply never mentions the corpus is unmeasured too" \
  "$(live_corpus_report "$(printf '%s\n' 'Test run with 10 tests in 1 suite passed after 0.029 seconds.')" "${TODAY}" "${SEEN_BOTH}")" \
  "Live store invariants: NOT REPORTED. This run printed no corpus line, so whether they measured anything is unknown; a scoped run does not include them."

# It reads the line out of a whole run's output, not just a line handed to it on its own, which is how
# it is really called.
assert_eq "the corpus line is found inside a full run's output" \
  "$(live_corpus_report "$(printf '%s\n%s\n%s\n' 'some noise' "${CORPUS_DORMANT}" 'more noise')" "${TODAY}" "${SEEN_BOTH}")" \
  "Live store invariants: DORMANT. The writer-resolution invariant has measured nothing since 2026-06-14 (70 days), the reached-out one since 2026-08-19 (4 days), so both passed having asserted nothing about Dan's real data (#2991, L182)."

# ---------------------------------------------------------------------------
# live_corpus_seen_update: what gets REMEMBERED, kept pure so the rules are testable
# ---------------------------------------------------------------------------
# The merge is a pure function returning the file's new contents; the call site only writes what it
# returns. That is what lets every rule below be checked without touching a file.

# A run that MEASURED something stamps that invariant with today's date. Only that one: the other's
# last-measured date is the whole thing being preserved.
assert_eq "an invariant that measured something is stamped with today" \
  "$(live_corpus_seen_update "${CORPUS_HALF}" "${TODAY}" "${SEEN_BOTH}")" \
  "writer=2026-06-14
reached=2026-08-23"

assert_eq "both are stamped when both measured" \
  "$(live_corpus_seen_update "${CORPUS_LIVE}" "${TODAY}" "${SEEN_BOTH}")" \
  "writer=2026-08-23
reached=2026-08-23"

# The case the whole feature rests on: a run where neither measured anything must CHANGE NOTHING, or
# the record would be overwritten with today every single run and the duration would always read zero,
# which is the defect wearing a date.
assert_eq "a dormant run stamps nothing at all" \
  "$(live_corpus_seen_update "${CORPUS_DORMANT}" "${TODAY}" "${SEEN_BOTH}")" \
  "${SEEN_BOTH}"

# And a run that took no reading is not evidence about anything, so it must not write either. A scoped
# run produces exactly this, and it happens constantly.
assert_eq "a run with no corpus line leaves the record untouched" \
  "$(live_corpus_seen_update "" "${TODAY}" "${SEEN_BOTH}")" \
  "${SEEN_BOTH}"

# A first record on a fresh clone is written, rather than needing a file to already exist.
assert_eq "a first measurement records itself on a clone with no file" \
  "$(live_corpus_seen_update "${CORPUS_LIVE}" "${TODAY}" "${SEEN_NEITHER}")" \
  "writer=2026-08-23
reached=2026-08-23"

# ---------------------------------------------------------------------------
# days_since: the duration, and its refusal
# ---------------------------------------------------------------------------

assert_eq "a duration is whole days between the two dates" \
  "$(days_since "2026-06-14" "2026-08-23")" "70"

assert_eq "the same day is zero days, not blank" \
  "$(days_since "2026-08-23" "2026-08-23")" "0"

# A date it cannot read produces NOTHING rather than a zero, because zero days is a measurement and an
# unreadable date is not one (L11).
assert_eq "an unreadable date yields no duration rather than a zero" \
  "$(days_since "not-a-date" "2026-08-23")" ""

# --- every corpus line written ANYWHERE in this repo is one the parser can read (#3165) --------------
#
# The line is spelled in five places: the Swift test that prints it, the parser that reads it, this
# fixture, `mac/scripts/run-tests-locked.test.sh`, and AGENTS.md. #3165 changed which clause the parser
# reads and updated four of them; the fifth went red only in a full `scripts/test-all.sh` run minutes
# later, and it reported the readout as UNMEASURED rather than as a wording mismatch, which is the least
# informative possible way to learn about it.
#
# So the rule is asked of the TREE rather than of a list somebody maintains: every `LIVE STORE CORPUS:`
# string in the repository must be one `live_corpus_counts` can parse. A sixth spelling is then caught by
# the fixture that owns the parser, in seconds, instead of by a suite run.
REPO_FOR_CORPUS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CORPUS_LINES="$(grep -rhoa 'LIVE STORE CORPUS: [^"]*' \
  "${REPO_FOR_CORPUS}/mac/scripts" "${REPO_FOR_CORPUS}/mac/OvertureTests" "${REPO_FOR_CORPUS}/AGENTS.md" \
  2>/dev/null | grep -a 'reached-out rows in play' || true)"
assert_eq "there really are corpus lines to check, so this is not passing over an empty list" \
  "$([ -n "${CORPUS_LINES}" ] && echo 1 || echo 0)" "1"

UNPARSEABLE=""
while IFS= read -r corpus_line; do
  [ -n "${corpus_line}" ] || continue
  # The Swift source writes the line with interpolations rather than numbers, so a line still carrying
  # one is the TEMPLATE and cannot be parsed as it stands. Its clause wording is checked below instead.
  case "${corpus_line}" in *'\('*) continue ;; esac
  live_corpus_counts "${corpus_line}" >/dev/null 2>&1 || UNPARSEABLE="${UNPARSEABLE} ${corpus_line}"
done <<< "${CORPUS_LINES}"
assert_eq "every corpus line spelled anywhere in the repo is one the parser can read" "${UNPARSEABLE}" ""

# And the TEMPLATE the Swift test prints carries the clause the parser looks for, which is the half the
# check above cannot ask, because a template holds interpolations rather than numbers.
# Counted as "at least one" rather than as an exact number: the clause legitimately appears both in the
# printed line and in the comment above it explaining why that clause is the one the readout is measured
# by, and pinning the count would fail on an edit that only reworded the comment.
assert_eq "the test that PRINTS the line writes the clause the parser reads" \
  "$([ "$(grep -ac 'whose writer a contact holds' \
            "${REPO_FOR_CORPUS}/mac/OvertureTests/ReplyInvariantsLiveStoreTests.swift" || echo 0)" -ge 1 ] \
     && echo yes || echo no)" "yes"


# --- a MIXED run, one testable parallel and one serial (#3266) -----------------------------------
#
# The shape the parallel work actually produces: `OvertureTests` parallelizable, `OvertureHostedTests`
# left serial because it launches the app. Such a run prints per-test lines for the parallel testable
# and NO summary, and a summary for the serial one and no per-test lines.
#
# Preferring the summary, which is what this did, read the hosted suite's 300 as the whole run.
# Measured 2026-08-30: a COMPLETE run (8,323 distinct parallel names plus that 300, against a baseline
# of 8,624) was reported as 300 tests and refused by the short-run gate. Under-reporting by 96% makes
# the gate block a healthy push, which is the failure that gets a gate switched off rather than trusted.
MIXED_LOG="$(cat "${SCRIPT_DIR}/fixtures/mixed-run-20260830.log")"

assert_eq "a mixed run counts BOTH testables, not whichever printed a summary" \
  "$(test_run_totals "${MIXED_LOG}" | awk '{print $1}')" \
  "303"

assert_eq "and its suites are both testables' too" \
  "$(test_run_totals "${MIXED_LOG}" | awk '{print $2}')" \
  "52"

# The DURATION is the one number that must NOT be summed. The parallel reading already takes the run's
# own elapsed line, which spans both testables, so adding the serial half's 5.207s to it would count
# that stretch twice and report a run as longer than it was.
assert_eq "the duration comes from the run's own elapsed line, never the sum" \
  "$(test_run_totals "${MIXED_LOG}" | awk '{print $3}')" \
  "162.335"

# Summing cannot double count, and that is measured rather than assumed: a wholly serial run prints no
# per-test worker lines at all, so the two sources never describe the same test. This pins the half that
# would break first if that ever changed.
assert_eq "a wholly serial run is still read from its summaries alone" \
  "$(test_run_totals "Test run with 10 tests in 2 suites passed after 1.500 seconds.")" \
  "10 2 1.500"

# ---------------------------------------------------------------------------
# The count comes from the RESULT BUNDLE, not from the log text (#3243, #3265)
# ---------------------------------------------------------------------------
#
# The count is the number that decides whether a run is trustworthy at all, and until now it was parsed
# out of xcodebuild's stdout. In a parallel run that stdout is written by several worker processes at
# once and their lines can collide: in the 2026-08-29 experiment log exactly one line was corrupted that
# way, which is why the readable count was 4,874 against the bundle's 4,875. One test is immaterial
# against a 10 percent tolerance; what is not immaterial is that the only thing bounding the error is
# how often two workers write in the same instant, which nothing measures and which gets worse with more
# workers.
#
# It also settles #3265, which is the sharper half. The gate compares a parallel run's count against a
# baseline recorded by a SERIAL run, and the two were produced differently: 8,612 by distinct name in
# parallel against a serial 8,618, with `CityFromAddressTests` alone printing 17 case lines under 6
# distinct names. Two numbers being CLOSE is worse than their being obviously different, because it
# reads as trustworthy while comparing two things that are not the same quantity. The bundle's
# `totalTestCount` is ONE quantity, produced the same way whatever the parallelism: measured 2026-08-30
# on a real serial run, `totalTestCount` is 8,626 against a summary line of 8,626, and the CASE count is
# 8,801 in the same bundle (45 tests ran with dynamic parameters over 220 runs). Names, both sides.

BUNDLE_STUB_DIR="$(fixture_scratch_dir)"
trap 'rm -rf "${BUNDLE_STUB_DIR}"' EXIT

make_xcresulttool_stub() {
  # $1 is what the stub prints, $2 its exit status.
  printf '#!/usr/bin/env bash\ncat <<%s\n%s\n%s\nexit %s\n' "JSON" "$1" "JSON" "${2:-0}" \
    > "${BUNDLE_STUB_DIR}/xcresulttool"
  chmod +x "${BUNDLE_STUB_DIR}/xcresulttool"
  echo "${BUNDLE_STUB_DIR}/xcresulttool"
}

RESULTS_LOG='Test session results, code coverage, and logs:
	/tmp/DerivedData/Logs/Test/Test-Overture-2026.08.30_10-47-49--0400.xcresult

** TEST SUCCEEDED **'

assert_eq "the result bundle path is read out of the run own output" \
  "$(test_run_result_bundle "${RESULTS_LOG}")" \
  "/tmp/DerivedData/Logs/Test/Test-Overture-2026.08.30_10-47-49--0400.xcresult"

# A retried run (the #1331 app-host flake) writes a second bundle, and the LAST one is the run whose
# result anybody is reading. Taking the first would read the count of the attempt that died.
TWO_BUNDLES_LOG="${RESULTS_LOG}
Test session results, code coverage, and logs:
	/tmp/DerivedData/Logs/Test/Test-Overture-2026.08.30_11-02-11--0400.xcresult
"
assert_eq "a retried run is read from its LAST bundle, not its first" \
  "$(test_run_result_bundle "${TWO_BUNDLES_LOG}")" \
  "/tmp/DerivedData/Logs/Test/Test-Overture-2026.08.30_11-02-11--0400.xcresult"

assert_eq "a run that named no bundle yields nothing rather than a guess" \
  "$(test_run_result_bundle '** TEST SUCCEEDED **')" ""

# --- reading the count out of a bundle ---------------------------------------------------------------

STUB="$(make_xcresulttool_stub '{ "totalTestCount" : 8626, "result" : "Passed" }' 0)"
assert_eq "the bundle count is read" \
  "$(OVERTURE_XCRESULTTOOL="${STUB}" result_bundle_total_test_count /tmp/some.xcresult)" "8626"

# Every way the reading can fail must come back EMPTY, never zero. Zero is a real measurement (a run
# that executed nothing) and the empty-run gate acts on it, so a failed read arriving as zero would
# fail a healthy run and name the wrong cause (L98, L11).
STUB_FAILS="$(make_xcresulttool_stub 'xcresulttool: could not open bundle' 1)"
assert_eq "a tool that refuses yields nothing, not zero" \
  "$(OVERTURE_XCRESULTTOOL="${STUB_FAILS}" result_bundle_total_test_count /tmp/some.xcresult)" ""

STUB_NO_KEY="$(make_xcresulttool_stub '{ "result" : "Passed" }' 0)"
assert_eq "a summary with no totalTestCount yields nothing" \
  "$(OVERTURE_XCRESULTTOOL="${STUB_NO_KEY}" result_bundle_total_test_count /tmp/some.xcresult)" ""

STUB_JUNK="$(make_xcresulttool_stub 'not json at all' 0)"
assert_eq "output that is not JSON yields nothing" \
  "$(OVERTURE_XCRESULTTOOL="${STUB_JUNK}" result_bundle_total_test_count /tmp/some.xcresult)" ""

assert_eq "and an empty bundle path is not asked about at all" \
  "$(OVERTURE_XCRESULTTOOL="${STUB}" result_bundle_total_test_count "")" ""

# --- which count wins, and the run says which one it used --------------------------------------------

assert_eq "the bundle count replaces the text count" \
  "$(totals_with_authoritative_count "8612 1176 366.413" "8626" "")" "8626 1176 366.413 xcresult"

assert_eq "and the suites and the duration still come from the text, which the bundle does not carry" \
  "$(totals_with_authoritative_count "8612 1176 366.413" "8626" "" | awk '{print $2, $3}')" "1176 366.413"

assert_eq "with no bundle count the text count stands, and says so" \
  "$(totals_with_authoritative_count "8612 1176 366.413" "" "")" "8612 1176 366.413 log"

# A RESTARTED run is refused the bundle count, deliberately. Its text totals are the totals of the
# REMAINDER after the relaunch (#2821), and whether the bundle counts the whole run or the remainder is
# not something anybody has measured. Substituting an unmeasured whole-run count for a remainder is the
# one direction that disarms the short-run gate, so the restart keeps the reading it already had (L82).
assert_eq "a restarted run keeps its own count rather than an unmeasured one" \
  "$(totals_with_authoritative_count "12 2 40.0" "8626" "restarted")" "12 2 40.0 log"

# Nothing to read at all stays nothing. An empty text reading plus no bundle is UNMEASURED, and it must
# not acquire a source word that makes it look like a reading somebody took.
assert_eq "no text and no bundle is still nothing" \
  "$(totals_with_authoritative_count "" "" "")" ""

# A bundle count with no text totals is still worth having: it is the count the gate needs, and the
# suites and duration honestly say they were not reported rather than being invented.
assert_eq "a bundle count with no text totals reports the count and admits the rest" \
  "$(totals_with_authoritative_count "" "8626" "")" "8626 unknown unknown xcresult"

# --- the readout says when it fell back to the log ---------------------------------------------------

FELL_BACK="$(format_suite_report "8612 1176 366.413 log" "1.91 to 1" "2204" "8628")"
assert_contains "the readout warns when the count came from the log text" "${FELL_BACK}" \
  "counted from the log text"
FROM_BUNDLE="$(format_suite_report "8626 1176 366.413 xcresult" "1.91 to 1" "2204" "8628")"
assert_not_contains "and says nothing extra when it came from the bundle" "${FROM_BUNDLE}" \
  "counted from the log text"
assert_contains "which is still the ordinary readout" "${FROM_BUNDLE}" "8626 tests in 1176 suites, 366.413s."

# --- NOT REPORTED names the cause it measured, not the one it guessed (#3275) -------------------------
#
# `ReplyInvariantsLiveStoreTests` prints its corpus line with `print()`, and a parallel worker's stdout
# does not reach xcodebuild's. Measured 2026-08-30 on a real parallel run: the suite RAN (its tests are
# in the log, passed) and the corpus line appears zero times. The message printed was
# `NOT REPORTED ... a scoped run does not include them` for a run that was not scoped, which names a
# cause that is not the cause and sends the reader to check a scope they never set (L11).
PARALLEL_NO_CORPUS="Test case 'ReplyIdentityTests/aPeerHoldsTheWriter()' passed on 'My Mac - xctest (63822)' (0.004 seconds)
Test case 'ReplyInvariantsLiveStoreTests/everyReachedOutRowHasSomeWayToReachThePerson()' passed on 'My Mac - xctest (63822)' (137.995 seconds)
** TEST SUCCEEDED **"
PARALLEL_CORPUS_REPORT="$(live_corpus_report "${PARALLEL_NO_CORPUS}" "2026-08-30" "")"
assert_contains "a parallel run with no corpus line still says NOT REPORTED" \
  "${PARALLEL_CORPUS_REPORT}" "NOT REPORTED"
assert_contains "and names the cause it can actually see" "${PARALLEL_CORPUS_REPORT}" "PARALLEL run"
assert_not_contains "rather than blaming a scope this run did not have" \
  "${PARALLEL_CORPUS_REPORT}" "a scoped run does not include them"

# The serial case keeps the wording it had, because there the scope really is the likely cause: a
# scoped run does not include that suite, and nothing else in a serial run swallows a print.
SERIAL_NO_CORPUS="${PASS_MARK} Test run with 10 tests in 1 suite passed after 0.029 seconds."
SERIAL_CORPUS_REPORT="$(live_corpus_report "${SERIAL_NO_CORPUS}" "2026-08-30" "")"
assert_contains "a serial run with no corpus line still names the scope" \
  "${SERIAL_CORPUS_REPORT}" "a scoped run does not include them"

# And a run that DID report keeps reporting, so the new branch cannot swallow the measuring case.
MEASURED_CORPUS="LIVE STORE CORPUS: 4 whose writer a contact holds, 4 reached-out rows in play
${PASS_MARK} Test run with 10 tests in 1 suite passed after 0.029 seconds."
assert_not_contains "a run that printed its corpus line is not NOT REPORTED" \
  "$(live_corpus_report "${MEASURED_CORPUS}" "2026-08-30" "")" "NOT REPORTED"

# ---------------------------------------------------------------------------
# #3276: the corpus reading survives a parallel run, because it no longer comes from stdout
# ---------------------------------------------------------------------------
# The suite now RECORDS its counts to a file the runner names, as well as printing them. A worker
# process has a filesystem; it does not have xcodebuild's stdout. So the reading is taken from the file
# wherever there is one, and from the log otherwise.
#
# Both sources carry the SAME sentence, built once by `LiveCorpusReport.line`, which is why one parser
# reads either: two spellings of this line is how the file and the fallback would come to report
# different numbers (L263).

assert_eq "the file wins when it carries a corpus line" \
  "$(corpus_source_text "${CORPUS_LIVE}" "${PARALLEL_NO_CORPUS}")" \
  "${CORPUS_LIVE}"

assert_eq "the log is the fallback when there is no file" \
  "$(corpus_source_text "" "${CORPUS_LIVE}")" \
  "${CORPUS_LIVE}"

# A file that exists and holds something else is NOT a reading. Without this a truncated or half-written
# file would be preferred over a log line that was perfectly good, which is the fallback being disabled
# by the very thing it exists to cover (L214).
assert_eq "a file with no corpus line in it falls back to the log" \
  "$(corpus_source_text "some other text entirely" "${CORPUS_LIVE}")" \
  "${CORPUS_LIVE}"

# The case the whole change is for: a PARALLEL run whose log carries no corpus line at all, and whose
# recorded file does. Before this it reported NOT REPORTED, so turning parallel testing on would have
# made the readout permanently silent and put the thing #2991 exists to notice back out of sight (L182).
PARALLEL_WITH_FILE="$(live_corpus_report "${PARALLEL_NO_CORPUS}" "${TODAY}" "${SEEN_BOTH}" "${CORPUS_LIVE}")"
assert_eq "a parallel run reports the counts its record file carries" \
  "${PARALLEL_WITH_FILE}" \
  "Live store invariants: measuring, over 3 rows the writer-resolution rule can judge and 5 reached-out rows in play."
assert_not_contains "and is no longer NOT REPORTED" "${PARALLEL_WITH_FILE}" "NOT REPORTED"

# And the DURABLE record moves with it. The report and the record must be taken from the same source or
# a parallel run would print its counts and leave the dormancy date untouched, which is the one number
# #2991 must never get wrong (L263).
assert_eq "a parallel run's record is updated from the same file" \
  "$(live_corpus_seen_update "${PARALLEL_NO_CORPUS}" "${TODAY}" "${SEEN_BOTH}" "${CORPUS_LIVE}")" \
  "writer=${TODAY}
reached=${TODAY}"

# A dormant parallel run still leaves the record alone, so the refusal that is the whole mechanism of
# #2991 is not lost by moving where the counts come from.
assert_eq "a dormant parallel run still writes nothing" \
  "$(live_corpus_seen_update "${PARALLEL_NO_CORPUS}" "${TODAY}" "${SEEN_BOTH}" "${CORPUS_DORMANT}")" \
  "${SEEN_BOTH}"

# Neither source is still NOT REPORTED, which is what a scoped run produces. An unmeasured reading must
# never read as a measured zero (L98).
assert_contains "neither a file nor a printed line is still NOT REPORTED" \
  "$(live_corpus_report "${PARALLEL_NO_CORPUS}" "${TODAY}" "${SEEN_BOTH}" "")" "NOT REPORTED"

# ---------------------------------------------------------------------------
# #3266: a run whose test process was KILLED at a time limit says so, and states no size
# ---------------------------------------------------------------------------
# This is the cause of every short run this repository has recorded. A test that exceeds its
# `.timeLimit` is killed, xcodebuild relaunches the test process and carries on, and the totals it
# prints afterwards are the totals of the remainder. Measured over twenty-three full parallel runs:
# seventeen complete ones carry no such failure and all six short ones carry exactly one.
#
# The log cannot show it. `Restarting after unexpected exit` appears ZERO times in every one of those
# short-run logs, so the existing check stays silent and the run reports a plausible small number, which
# is precisely the answer #2821 says it must never give.

KILL_SUMMARY='{ "totalTestCount" : 5087, "testFailures" : [ { "testName" : "aCheckStartedWhileAPrepIsLiveIsStillFollowed()", "failureText" : "Test exceeded execution time allowance of 1 minute" } ] }'
CLEAN_SUMMARY='{ "totalTestCount" : 8643, "testFailures" : [ { "testName" : "somethingElse()", "failureText" : "Expectation failed: 1 == 2" } ] }'

STUB_KILL="$(make_xcresulttool_stub "${KILL_SUMMARY}" 0)"
assert_eq "a bundle whose summary names a time limit kill reports the test" \
  "$(OVERTURE_XCRESULTTOOL="${STUB_KILL}" result_bundle_time_limit_kill /tmp/whatever.xcresult)" \
  "aCheckStartedWhileAPrepIsLiveIsStillFollowed()"

# An ordinary failure is NOT a kill. Without this the reading would fire on any red run at all, which is
# the shape that gets a check switched off within a day (L93).
STUB_CLEAN="$(make_xcresulttool_stub "${CLEAN_SUMMARY}" 0)"
assert_empty "an ordinary test failure is not a time limit kill" \
  "$(OVERTURE_XCRESULTTOOL="${STUB_CLEAN}" result_bundle_time_limit_kill /tmp/whatever.xcresult)"

# Every way the read can fail comes back EMPTY rather than as a false "no kill", because an unreadable
# bundle must not read as a clean run (L98). Three ways, each driven separately.
STUB_BROKEN="$(make_xcresulttool_stub 'xcresulttool: could not open bundle' 1)"
assert_empty "an unreadable bundle yields nothing" \
  "$(OVERTURE_XCRESULTTOOL="${STUB_BROKEN}" result_bundle_time_limit_kill /tmp/whatever.xcresult)"
STUB_JUNK2="$(make_xcresulttool_stub 'not json at all' 0)"
assert_empty "a summary that is not JSON yields nothing" \
  "$(OVERTURE_XCRESULTTOOL="${STUB_JUNK2}" result_bundle_time_limit_kill /tmp/whatever.xcresult)"
STUB_NOKEY="$(make_xcresulttool_stub '{ "totalTestCount" : 10 }' 0)"
assert_empty "a summary with no testFailures yields nothing" \
  "$(OVERTURE_XCRESULTTOOL="${STUB_NOKEY}" result_bundle_time_limit_kill /tmp/whatever.xcresult)"
assert_empty "no bundle path yields nothing" \
  "$(OVERTURE_XCRESULTTOOL="${STUB_KILL}" result_bundle_time_limit_kill "")"

# And the readout NAMES the test, which is the whole difference between a re-run and a fix. The reason
# was previously unavailable anywhere: the log says nothing and the old message could only guess between
# three causes (L11).
KILL_REPORT="$(format_suite_report "5087 785 182.509" "1.92 to 1" "2206" "8647" "time-limit aCheckStartedWhileAPrepIsLiveIsStillFollowed()")"
assert_contains "a killed run states no size" "${KILL_REPORT}" "NOT REPORTED"
assert_contains "and names the test that was killed" \
  "${KILL_REPORT}" "aCheckStartedWhileAPrepIsLiveIsStillFollowed()"
assert_contains "and says the counts are of the remainder" "${KILL_REPORT}" "AFTER that"
assert_not_contains "and does not print the remainder as if it were the suite" "${KILL_REPORT}" "5087 tests"

# A restart detected the OLD way keeps its own words, because that one really is a choice of three
# causes and naming a test it does not know would be a claim nothing measured (L11).
PLAIN_RESTART_REPORT="$(format_suite_report "12 2 0.6" "1.92 to 1" "2206" "8647" "restarted")"
assert_contains "a restart with no named cause still says NOT REPORTED" "${PLAIN_RESTART_REPORT}" "NOT REPORTED"
assert_contains "and keeps the wording that lists the causes it cannot tell apart" \
  "${PLAIN_RESTART_REPORT}" "unexpected exit, crash or test timeout"

# And a healthy run is untouched by any of it.
assert_contains "a run that was not killed still states its size" \
  "$(format_suite_report "8643 1179 144.834" "1.92 to 1" "2206" "8647" "")" "8643 tests in 1179 suites"

# ---------------------------------------------------------------------------
# #3385: the kill is readable from the run's OWN OUTPUT, so one unreadable bundle cannot take both
# ---------------------------------------------------------------------------
# #3384 read the kill from the result bundle only, and the bundle is also where the executed count comes
# from. Measured on the first real truncated run after it shipped: the bundle could not be read, so the
# detection said nothing AND the count fell back to the log text, and the readout printed
# `5035 tests in 782 suites` for a run that had lost 3,608 tests. A guard must not draw on the same
# source as the reading it would refuse.
#
# The signature needs no list of declared limits: Swift Testing expresses a time limit in whole MINUTES,
# so a killed test reports a whole number of minutes in seconds to three decimals.

KILLED_LINE="Test case 'RunStateIsPerSlotTests/aCheckStartedWhileAPrepIsLiveIsStillFollowed()' failed on 'My Mac - xctest (92479)' (60.000 seconds)"
assert_eq "a failed test at exactly one minute is a time limit kill" \
  "$(output_time_limit_kill "${KILLED_LINE}")" \
  "RunStateIsPerSlotTests/aCheckStartedWhileAPrepIsLiveIsStillFollowed()"

# A longer limit, so the reading is not the number 60 (L70: a check that only ever sees one value proves
# nothing about the rule it claims to apply).
assert_eq "a failed test at exactly three minutes is one too" \
  "$(output_time_limit_kill "Test case 'Slow/thing()' failed on 'My Mac - xctest (1)' (180.000 seconds)")" \
  "Slow/thing()"

# A PASSING test is never a kill, whatever its duration reads. This is the case that stops the rule
# firing on the ordinary parallel log, where the seconds are elapsed since the worker began rather than
# what the test cost, so a whole minute lands there constantly (L93).
assert_empty "a passing test at exactly one minute is not a kill" \
  "$(output_time_limit_kill "Test case 'Fine/thing()' failed_not on 'My Mac - xctest (1)' (60.000 seconds)
Test case 'Fine/other()' passed on 'My Mac - xctest (1)' (60.000 seconds)")"

# An ordinary failure is not a kill either, or the reading would fire on every red run there is.
assert_empty "an ordinary failure at a fractional duration is not a kill" \
  "$(output_time_limit_kill "Test case 'Red/thing()' failed on 'My Mac - xctest (1)' (0.013 seconds)")"

# And a duration that is a whole number of SECONDS but not of minutes is not a limit, since a limit
# cannot be expressed that way.
assert_empty "a failure at thirty seconds is not a time limit" \
  "$(output_time_limit_kill "Test case 'Red/thing()' failed on 'My Mac - xctest (1)' (30.000 seconds)")"

assert_empty "a run with no test lines at all yields nothing" "$(output_time_limit_kill "")"

echo
# ---------------------------------------------------------------------------
# #3348: a failing test's REASON, which does not reach the log under parallel testing
# ---------------------------------------------------------------------------
# Measured 2026-08-30, both sides in one session. A SERIAL run prints
# `recorded an issue at WaitUntilTests.swift:151:9: Expectation failed: (polls -> 100) == 2`. Three full
# PARALLEL runs carrying three real failures between them contain ZERO occurrences of
# `Expectation failed` or `recorded an issue`: a parallel worker's stdout does not reach xcodebuild's,
# and Swift Testing writes an issue's text there. What survives is xcodebuild's own `Failing tests:`
# block, which is names only, so a red run becomes a list nobody can diagnose from.
#
# The reason IS in the run's own result bundle, in the same `summary` call the executed count already
# makes, so nothing has to be added to the tests and no second `xcresulttool` invocation is paid for.

REASONS_SUMMARY='{ "totalTestCount" : 20, "testFailures" : [
  { "testName" : "aGuardHolds()", "testIdentifierString" : "BarTests/aGuardHolds()", "targetName" : "OvertureTests", "failureText" : "Expectation failed: the venue guard did not fire" },
  { "testName" : "wraps()", "testIdentifierString" : "BazTests/wraps()", "targetName" : "OvertureTests", "failureText" : "Expectation failed: (body ->\n  \"two lines\") is wrong" } ] }'
STUB_REASONS="$(make_xcresulttool_stub "${REASONS_SUMMARY}" 0)"

# The identifier is normalised to xcodebuild's own spelling, since the bundle writes `Suite/test()` and
# the block writes `Suite.test()`, and a reason that cannot be paired with a name is no use.
assert_eq "each failure comes back as its test and its reason" \
  "$(OVERTURE_XCRESULTTOOL="${STUB_REASONS}" result_bundle_failure_reasons /tmp/a.xcresult)" \
  "BarTests.aGuardHolds()	Expectation failed: the venue guard did not fire
BazTests.wraps()	Expectation failed: (body -> \"two lines\") is wrong"

# One line per failure, whatever the reason contains. Swift Testing routinely records a multi-line body
# in an expectation's text, and a reason spilling onto its own lines would break the pairing above and
# read as several failures.
assert_eq "a multi-line reason is collapsed onto one line" \
  "$(OVERTURE_XCRESULTTOOL="${STUB_REASONS}" result_bundle_failure_reasons /tmp/a.xcresult | grep -c .)" \
  "2"

# Read versus unreadable, told apart by STATUS rather than by silence, because a bundle that could not be
# opened and a run whose failures carry no text look identical from an empty answer (L98, L11).
OVERTURE_XCRESULTTOOL="${STUB_REASONS}" result_bundle_failure_reasons /tmp/a.xcresult >/dev/null 2>&1
assert_eq "a bundle that was read reports success" "0" "$?"
STUB_UNREADABLE="$(make_xcresulttool_stub 'xcresulttool: could not open bundle' 1)"
OVERTURE_XCRESULTTOOL="${STUB_UNREADABLE}" result_bundle_failure_reasons /tmp/a.xcresult >/dev/null 2>&1
assert_eq "a bundle that could not be read reports failure" "1" "$?"
STUB_NOT_JSON="$(make_xcresulttool_stub 'not json at all' 0)"
OVERTURE_XCRESULTTOOL="${STUB_NOT_JSON}" result_bundle_failure_reasons /tmp/a.xcresult >/dev/null 2>&1
assert_eq "a summary that is not JSON reports failure too" "1" "$?"
OVERTURE_XCRESULTTOOL="${STUB_REASONS}" result_bundle_failure_reasons "" >/dev/null 2>&1
assert_eq "and no bundle path at all reports failure" "1" "$?"

# A summary that READ but names no failure is a different state again, and it is not an error: it is
# what a green bundle says. It prints nothing and succeeds.
STUB_NO_FAILURES="$(make_xcresulttool_stub '{ "totalTestCount" : 10, "testFailures" : [] }' 0)"
assert_empty "a bundle recording no failure prints nothing" \
  "$(OVERTURE_XCRESULTTOOL="${STUB_NO_FAILURES}" result_bundle_failure_reasons /tmp/a.xcresult)"

# --- and the reprint carries them, beside the names rather than instead of them -----------------------
# The `Failing tests:` block is xcodebuild's own list and is what the count is taken from, so this adds
# the reason under each name and never replaces the list (#2600 is why the list leads).
REASONS_OUTPUT="Failing tests:
	OvertureTests.BarTests.aGuardHolds()
	OvertureTests.BazTests.wraps()

** TEST FAILED **"

# Re-made here rather than reused from above: `make_xcresulttool_stub` writes to ONE fixed path, so the
# stub built last is the one every earlier handle now points at. Found by writing these assertions, which
# read the empty-failures stub and reported every test as having no reason.
STUB_REASONS="$(make_xcresulttool_stub "${REASONS_SUMMARY}" 0)"
PAIRED="$(OVERTURE_XCRESULTTOOL="${STUB_REASONS}" failing_tests_report "${REASONS_OUTPUT}" /tmp/a.xcresult)"
assert_contains "the reprint still leads with the count" "${PAIRED}" "FAILING TESTS (2)"
assert_contains "and still names every test xcodebuild named" "${PAIRED}" "OvertureTests.BarTests.aGuardHolds()"
assert_contains "and carries the reason under it" "${PAIRED}" "the venue guard did not fire"
assert_contains "and the reason of the second one too" "${PAIRED}" "two lines"

# A name the bundle records no failure for says so in its own words rather than showing a blank, because
# a missing reason and a reason nobody read must not look the same (L11).
STUB_REASONS="$(make_xcresulttool_stub "${REASONS_SUMMARY}" 0)"
ONE_KNOWN="$(OVERTURE_XCRESULTTOOL="${STUB_REASONS}" failing_tests_report "Failing tests:
	OvertureTests.BarTests.aGuardHolds()
	OvertureTests.QuxTests.somethingElse()

** TEST FAILED **" /tmp/a.xcresult)"
assert_contains "a test the bundle records no failure for is named all the same" \
  "${ONE_KNOWN}" "OvertureTests.QuxTests.somethingElse()"
assert_contains "and says the bundle held no reason for it" "${ONE_KNOWN}" "NO REASON IN THE BUNDLE"

# An unreadable bundle SAYS so, and the names survive. Printing the list alone would be indistinguishable
# from a run whose failures genuinely carried no text (L98).
STUB_UNREADABLE="$(make_xcresulttool_stub 'xcresulttool: could not open bundle' 1)"
UNREADABLE_REPORT="$(OVERTURE_XCRESULTTOOL="${STUB_UNREADABLE}" failing_tests_report "${REASONS_OUTPUT}" /tmp/a.xcresult)"
assert_contains "an unreadable bundle still reprints every name" \
  "${UNREADABLE_REPORT}" "OvertureTests.BazTests.wraps()"
assert_contains "and says the reasons could not be read" "${UNREADABLE_REPORT}" "REASONS NOT READ"
assert_contains "and names the bundle it could not read" "${UNREADABLE_REPORT}" "/tmp/a.xcresult"

# A run whose output named no bundle at all is its own cause, and gets its own sentence.
NO_BUNDLE_REPORT="$(failing_tests_report "${REASONS_OUTPUT}" "")"
assert_contains "a run that named no result bundle still reprints the names" \
  "${NO_BUNDLE_REPORT}" "OvertureTests.BarTests.aGuardHolds()"
assert_contains "and says that is why there are no reasons" \
  "${NO_BUNDLE_REPORT}" "named no result bundle"

# The one-argument form is unchanged, so the callers that only ever want the list are untouched.
assert_eq "asked for the list alone, it is still the list alone" \
  "$(failing_tests_report "${REASONS_OUTPUT}")" \
  "FAILING TESTS (2), reprinted so the list is the last thing on screen:
  OvertureTests.BarTests.aGuardHolds()
  OvertureTests.BazTests.wraps()"

# A GREEN run reads no bundle at all, whatever it is handed. The count call already costs 6.2s and a run
# with nothing to report must not pay for a second one.
assert_empty "a passing run reports nothing even when a bundle is offered" \
  "$(OVERTURE_XCRESULTTOOL=/bin/false failing_tests_report "Test run with 10 tests in 2 suites passed after 1.0 seconds.
** TEST SUCCEEDED **" /tmp/a.xcresult)"

# WIRED, not merely callable (L3). The library being right is worth nothing if the runner still asks for
# the list alone: the one-argument form is still supported, so an unwired runner would print exactly what
# it printed before and nothing would go red. Asserted on the runner's source, because exercising it needs
# a real red xcodebuild run.
# Asserted as a COUNT rather than by handing the whole file to assert_contains, which would print the
# runner's source on failure. That source carries the line the runner prints when a run executes no
# tests, and `scripts/mutate.sh` reads its own run log for that phrase, so proving this guard by
# mutation reported NOTHING RAN for a run that had really gone red. L156 one level further out than the
# comment in mutate.sh that already records it: a check for a substring of the thing being talked about
# also matches a dump of the code that says it.
WIRED_BUNDLE_ARG="$(grep -cF 'failing_tests_report "${last_output}" "$(test_run_result_bundle "${last_output}")"' \
  "${SCRIPT_DIR}/../run-tests-locked.sh" || true)"
assert_eq "the runner hands the reprint a result bundle to read reasons from" "${WIRED_BUNDLE_ARG}" "1"

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All suite-stats.sh fixtures passed."
  exit 0
fi
echo "${FAILURES} suite-stats.sh fixture(s) failed." >&2
exit 1
