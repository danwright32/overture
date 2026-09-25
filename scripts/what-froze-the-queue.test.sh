#!/usr/bin/env bash
set -uo pipefail

# #3760: the judging half of scripts/what-froze-the-queue.sh, driven against built logs rather than the
# live one, so every outcome can be produced rather than waited for.
#
# The outcome that matters is the THIRD one. A log holding only records written before the pass count
# shipped, and a log where every stall is fully attributed, both leave nothing to report. Judging on that
# alone would make the emptiest possible failure read as the cleanest possible answer (L98, L11), and on
# Dan's Mac today EVERY record predates the field, so that is the state the tool actually starts in.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER="${SCRIPT_DIR}/what-froze-the-queue.sh"
FAILURES=0

WORK="$(fixture_scratch_dir)"
MAIN_SHELL_PID="${BASHPID:-$$}"
trap '[ "${BASHPID:-$$}" = "${MAIN_SHELL_PID}" ] && rm -rf "${WORK}"' EXIT

record() { # seconds passes [passSeconds]  -> one ndjson line; "none" omits the field entirely
  local seconds="$1" passes="$2" cost="${3:-none}" tail=""
  [ "${passes}" != "none" ] && tail=",\"passes\":${passes}"
  [ "${cost}" != "none" ] && tail="${tail},\"passSeconds\":${cost}"
  printf '{"session":"s","sequence":1,"at":"2026-09-10T17:47:37Z","seconds":%s,"surface":"queue","load":"baseline","loadAverage":3.7%s}\n' "${seconds}" "${tail}"
}

# 1. No log at all.
out="$("${READER}" --log "${WORK}/absent.ndjson" 2>&1)"; status=$?
assert_equals "a missing log is UNMEASURED rather than a clean bill" "2" "${status}"
assert_contains "and it says so" "${out}" "UNMEASURED"

# 2. A log holding only records from before the field shipped.
record 16.73 none > "${WORK}/old.ndjson"
record 10.84 none >> "${WORK}/old.ndjson"
out="$("${READER}" --log "${WORK}/old.ndjson" 2>&1)"; status=$?
assert_equals "a log with no pass count anywhere is UNMEASURED" "2" "${status}"
assert_contains "and it names why, rather than reporting no findings" "${out}" "no record carries a pass count"

# 3. Every stall spans passes. Attributed, nothing to look at.
record 16.73 48 > "${WORK}/attributed.ndjson"
record 0.31 1 >> "${WORK}/attributed.ndjson"
out="$("${READER}" --log "${WORK}/attributed.ndjson" 2>&1)"; status=$?
assert_equals "a fully attributed log has nothing to triage" "0" "${status}"
assert_contains "and it reports the count beside the duration" "${out}" "48"

# 4. A stall that counted NO pass. This is still the finding, and it is still worth exit 1, but #3783
#    changed what it is allowed to CONCLUDE. The counter is bumped by the first line of
#    QueueView.makeRenderData(), so it covers the body and nothing else. The @Query fetch that feeds
#    that body is paid BEFORE that line runs (#3750 prices it as its own arm), every other surface runs
#    its own derivation and bumps nothing (#3762), and plenty of main thread work is not a render pass
#    at all. Each of those reads as zero here, so zero cannot carry the claim "the surface did not
#    rebuild": that is a statement about a quantity this counter never measured (L11, L144, L440).
record 16.73 0 > "${WORK}/unexplained.ndjson"
record 0.31 2 >> "${WORK}/unexplained.ndjson"
out="$("${READER}" --log "${WORK}/unexplained.ndjson" 2>&1)"; status=$?
assert_equals "a stall counting no pass is something to look at" "1" "${status}"
assert_contains "and it calls the stall unattributed" "${out}" "UNATTRIBUTED"
assert_contains "and it names the fetch the counter cannot see" "${out}" "#3750"
assert_contains "and it names the surfaces that bump nothing" "${out}" "#3762"
assert_not_contains "and it no longer claims the surface did not rebuild" "${out}" "did not rebuild"

# 4b. #3783: the counter's REACH is stated whenever a reading is printed, not only when there is a
#     finding. A fully attributed log is the reading most likely to be quoted as "the render pass
#     accounts for it", and it is the one where the unmeasured terms are easiest to forget.
out="$("${READER}" --log "${WORK}/attributed.ndjson" 2>&1)"; status=$?
assert_equals "an attributed log still reports cleanly" "0" "${status}"
assert_contains "and it states what the count covers" "${out}" "counts QueueView"

# 4c. #3783: the MOST passes any stall spanned is printed. Measured on Dan's live log 2026-09-11, no
#     stall in 576 records ever spanned more than one, including a 29.35s one, and nothing printed that.
#     A single long stall reported as "spanning 1 pass(es)" reads as the pass accounting for it, which is
#     the reading this milestone would act on and the one the data refutes (L216, L629).
record 29.35 1 > "${WORK}/one-pass.ndjson"
record 0.31 1 >> "${WORK}/one-pass.ndjson"
out="$("${READER}" --log "${WORK}/one-pass.ndjson" 2>&1)"; status=$?
assert_equals "a log where every stall spans exactly one pass still reports" "0" "${status}"
assert_contains "and the most any stall spanned is stated" "${out}" "Most passes spanned by any stall: 1"

# 5. A mixed log. The counted records are judged; the uncounted ones are REPORTED as unjudged rather
#    than folded in either direction.
record 16.73 48 > "${WORK}/mixed.ndjson"
record 10.84 none >> "${WORK}/mixed.ndjson"
out="$("${READER}" --log "${WORK}/mixed.ndjson" 2>&1)"; status=$?
assert_equals "a mixed log judges what it can" "0" "${status}"
assert_contains "and says how many it could not judge" "${out}" "1 carry no pass count"

# 6. A log that exists and holds nothing is not the same as one that could not be read.
: > "${WORK}/empty.ndjson"
out="$("${READER}" --log "${WORK}/empty.ndjson" 2>&1)"; status=$?
assert_equals "an empty log is UNMEASURED" "2" "${status}"

# 7. #3763: the archive beside the live log is part of the population, and the tool SAYS what it read.
#    A compaction moves records out of the live file, so a reader that opens only that file silently
#    reports on the recent window while looking exactly like a reader of the whole history. The archive
#    is where the "before" half of milestone 80's comparison lives, so that narrowing would be invisible
#    and would quietly wreck the one reading it exists for (L46, L98).
#    Its own directory, and case 8's too. The archive is found by its FIXED name beside the log, so a case
#    that writes one into the shared work directory leaves it there for every case after it: case 8's
#    premise is that no archive exists, and sharing the directory silently removed that premise while the
#    case still read as passing (L447).
mkdir -p "${WORK}/with-archive" "${WORK}/without-archive"
record 16.73 48 > "${WORK}/with-archive/both.ndjson"
record 0.31 1 >> "${WORK}/with-archive/both.ndjson"
record 10.84 2 > "${WORK}/with-archive/freeze-log-archive.ndjson"
record 7.77 3 >> "${WORK}/with-archive/freeze-log-archive.ndjson"
out="$("${READER}" --log "${WORK}/with-archive/both.ndjson" 2>&1)"; status=$?
assert_equals "a log with an archive beside it still reports" "0" "${status}"
assert_contains "and the archived records are in the population" "${out}" "of 4 record(s)"
assert_contains "and it names the archive it read, so one file cannot pass for two" "${out}" "freeze-log-archive.ndjson"

# 8. The archive is OPTIONAL, and its absence must read as absent rather than as an error. Most installs
#    have never compacted, so this is the ordinary state rather than the edge case.
record 16.73 48 > "${WORK}/without-archive/alone.ndjson"
out="$("${READER}" --log "${WORK}/without-archive/alone.ndjson" 2>&1)"; status=$?
assert_equals "no archive beside the log is not a failure" "0" "${status}"
assert_contains "and the reading is still the live file's own" "${out}" "of 1 record(s)"


# #3815: the count alone cannot say whether the passes ACCOUNT for the freeze, and that is the question
# this tool exists to answer. A 16.73s stall spanning one pass has two incompatible explanations, and the
# duration beside the count is what chooses between them.

# 9. A long stall whose one pass took almost none of it: the pass does NOT account for the freeze.
mkdir -p "${WORK}/unaccounted"
record 16.73 1 0.172 > "${WORK}/unaccounted/log.ndjson"
out="$("${READER}" --log "${WORK}/unaccounted/log.ndjson" 2>&1)"; status=$?
assert_equals "a stall its passes cannot account for still reports" "0" "${status}"
assert_contains "and it says how much of the stall the passes were" "${out}" "1%"
assert_contains "and it names the reading rather than leaving it to arithmetic" "${out}" "do not account"

# 10. A long stall whose one pass took nearly all of it: the pass IS the freeze.
mkdir -p "${WORK}/accounted"
record 16.73 1 16.40 > "${WORK}/accounted/log.ndjson"
out="$("${READER}" --log "${WORK}/accounted/log.ndjson" 2>&1)"; status=$?
assert_equals "a stall its passes account for reports" "0" "${status}"
assert_contains "and it says the passes account for it" "${out}" "account for"
assert_not_contains "and does not also say they do not" "${out}" "do not account"

# 11. A record carrying a count and NO duration is not judged either way. Every record on Dan's Mac is
#     one of these today, and reading them as "the passes took no time" would be the instrument's
#     absence reading as a finding (L98).
mkdir -p "${WORK}/untimed"
record 16.73 1 none > "${WORK}/untimed/log.ndjson"
out="$("${READER}" --log "${WORK}/untimed/log.ndjson" 2>&1)"; status=$?
assert_contains "an untimed stall is named as untimed" "${out}" "carry no pass duration"
assert_not_contains "and is not read as a pass that took no time" "${out}" "do not account"

# 12. #3859: the two surface vocabularies are the same file, and a distribution that adds them together
#     is two populations in one number. The stamp is `surfaceVocabulary`, absent on every record written
#     before it shipped, so the reading has to say which half it is looking at (L216).
mkdir -p "${WORK}/vocab"
record 16.73 1 0.2 > "${WORK}/vocab/log.ndjson"
out="$("${READER}" --log "${WORK}/vocab/log.ndjson" 2>&1)"
assert_contains "a log of only pre-#3859 records says every queue is the mixed population" \
  "${out}" "Every record here predates #3859"
assert_contains "and counts them" "${out}" "1 record(s) written before #3859, 0 after"

# The mixed case, which is what Dan's own log will be for weeks after this ships.
mkdir -p "${WORK}/mixed"
record 16.73 1 0.2 > "${WORK}/mixed/log.ndjson"
printf '{"session":"s","sequence":2,"at":"2026-09-14T17:47:37Z","seconds":9.1,"surface":"patterns","load":"baseline","loadAverage":3.7,"surfaceVocabulary":14,"passes":1,"passSeconds":0.2}\n' \
  >> "${WORK}/mixed/log.ndjson"
out="$("${READER}" --log "${WORK}/mixed/log.ndjson" 2>&1)"
assert_contains "a mixed log counts both halves" "${out}" "1 record(s) written before #3859, 1 after"
assert_contains "and refuses to have them added together" "${out}" "Do not add the two counts together"
assert_not_contains "and does not claim the whole file predates the change" \
  "${out}" "Every record here predates"
assert_contains "and a sheet that used to read as the queue now names itself" "${out}" "patterns"

# 13. #3813: a stall that counted no render pass but DID count RootView draws is a rebuilding window, not
#     a main thread doing something that draws nothing, and the two call for different next steps. A
#     record with no root count at all says "?" rather than 0, because absent and none are different
#     answers (L98).
mkdir -p "${WORK}/root"
printf '{"session":"s","sequence":1,"at":"2026-09-14T17:47:37Z","seconds":9.1,"surface":"queue","load":"baseline","loadAverage":3.7,"passes":0,"passSeconds":0.0,"rootDraws":4}\n' \
  > "${WORK}/root/log.ndjson"
out="$("${READER}" --log "${WORK}/root/log.ndjson" 2>&1)"
assert_contains "a silent stall that drew the window says so" "${out}" "drew the window anyway"
assert_contains "and counts them" "${out}" "Of the 1 carrying a RootView draw count, 1"

mkdir -p "${WORK}/noroot"
record 9.1 0 0.0 > "${WORK}/noroot/log.ndjson"
out="$("${READER}" --log "${WORK}/noroot/log.ndjson" 2>&1)"
assert_contains "a silent stall from before #3813 says it cannot tell" "${out}" "cannot tell a rebuilding window"
assert_not_contains "and does not claim the window drew" "${out}" "drew the window anyway"

# 14. #4153: a record that spanned a SLEEP is not a freeze, and the reader has to say so rather than let
#     it set the maximum. Three states, and the difference between the first two is the whole point: a
#     log with no reading at all cannot tell a sleeping Mac from a frozen one, and must not imply it can.
mkdir -p "${WORK}/sleep"
printf '{"session":"s","sequence":1,"at":"2026-09-22T03:07:14Z","seconds":1057.9,"surface":"queue","load":"elevated","loadAverage":95.8,"passes":0,"passSeconds":0.0,"rootDraws":0,"asleepSeconds":1074.0}\n' \
  > "${WORK}/sleep/log.ndjson"
printf '{"session":"s","sequence":2,"at":"2026-09-22T15:24:00Z","seconds":18.64,"surface":"queue","load":"elevated","loadAverage":34.7,"passes":1,"passSeconds":9.53,"rootDraws":1,"asleepSeconds":0.0}\n' \
  >> "${WORK}/sleep/log.ndjson"
out="$("${READER}" --log "${WORK}/sleep/log.ndjson" 2>&1)"
assert_contains "a record that spanned a sleep is named as not a freeze" "${out}" "are NOT freezes"
assert_contains "and the sleep it spanned is quoted beside the duration it claims" "${out}" "1057.90s recorded, 1074.00s of it asleep"
assert_contains "and the maximum a reader should quote is the longest that slept through nothing" "${out}" "18.64s"

# The same file with every sleep reading removed, which is every record Dan has today. It must say it
# cannot tell rather than reporting a clean 1057.90s maximum (L98).
mkdir -p "${WORK}/nosleep"
printf '{"session":"s","sequence":1,"at":"2026-09-22T03:07:14Z","seconds":1057.9,"surface":"queue","load":"elevated","loadAverage":95.8,"passes":0,"passSeconds":0.0,"rootDraws":0}\n' \
  > "${WORK}/nosleep/log.ndjson"
out="$("${READER}" --log "${WORK}/nosleep/log.ndjson" 2>&1)"
assert_contains "a log with no sleep reading says so in those words" "${out}" "sleep: UNMEASURED"
assert_not_contains "and never claims a record stayed awake" "${out}" "spanned no sleep"

# And an awake machine is a positive statement rather than silence, so the clean day is sayable.
mkdir -p "${WORK}/awake"
printf '{"session":"s","sequence":1,"at":"2026-09-22T15:24:00Z","seconds":18.64,"surface":"queue","load":"elevated","loadAverage":34.7,"passes":1,"passSeconds":9.53,"rootDraws":1,"asleepSeconds":0.0}\n' \
  > "${WORK}/awake/log.ndjson"
out="$("${READER}" --log "${WORK}/awake/log.ndjson" 2>&1)"
assert_contains "a log where nothing slept says every duration is real" "${out}" "none of them spanned any"
assert_not_contains "and does not report a sleep that did not happen" "${out}" "are NOT freezes"

# 15. #4122: the live file is a truncated window with one promoted record in it, and a reader that counts
#     the compaction note as a stall inflates every figure it prints. Three states again, and the middle
#     one is the file Dan has today.
mkdir -p "${WORK}/window"
printf '{"note":"compaction","at":"2026-09-21T21:05:00Z","kept":2,"archived":443,"promotedAt":"2026-09-18T11:02:00Z","promotedSeconds":1047.9}\n' \
  > "${WORK}/window/log.ndjson"
printf '{"session":"s","sequence":1,"at":"2026-09-18T11:02:00Z","seconds":1047.9,"surface":"queue","load":"elevated","loadAverage":95.8,"passes":1,"passSeconds":0.2,"promotedFromOlderWindow":true}\n' \
  >> "${WORK}/window/log.ndjson"
printf '{"session":"s","sequence":2,"at":"2026-09-21T20:07:00Z","seconds":2.8,"surface":"queue","load":"baseline","loadAverage":3.7,"passes":1,"passSeconds":2.27}\n' \
  >> "${WORK}/window/log.ndjson"
out="$("${READER}" --log "${WORK}/window/log.ndjson" 2>&1)"
assert_contains "the window the file actually holds is stated before any figure from it" "${out}" "window: a compaction on"
assert_contains "and it names how many went to the archive" "${out}" "moved 443 to the archive"
assert_contains "and names the promoted record as not part of this window" "${out}" "PROMOTED from the older half"
assert_contains "the note is not counted as a stall" "${out}" "2 stall(s) with a pass count, of 2 record(s)"
assert_not_contains "and is not read as a line that could not be read" "${out}" "line(s) could not be read"

# The file with no note at all, which is every log written before #4122. It must say it cannot tell a
# never-compacted file from an older one, rather than implying the window is whole (L98).
mkdir -p "${WORK}/nonote"
record 2.8 1 2.27 > "${WORK}/nonote/log.ndjson"
out="$("${READER}" --log "${WORK}/nonote/log.ndjson" 2>&1)"
assert_contains "a file with no note says so" "${out}" "no compaction note in this reading"
assert_contains "and names the two facts it cannot separate" "${out}" "those are different facts"

# A compaction that promoted nothing is a positive statement, not silence.
mkdir -p "${WORK}/nopromote"
printf '{"note":"compaction","at":"2026-09-21T21:05:00Z","kept":1,"archived":12,"promotedAt":null,"promotedSeconds":null}\n' \
  > "${WORK}/nopromote/log.ndjson"
record 2.8 1 2.27 >> "${WORK}/nopromote/log.ndjson"
out="$("${READER}" --log "${WORK}/nopromote/log.ndjson" 2>&1)"
assert_contains "a compaction that promoted nothing says every record is inside the window" "${out}" "Nothing was promoted"
assert_not_contains "and does not claim one is out of band" "${out}" "PROMOTED from the older half"

# #4114: what the main run loop was doing, which is the half that separates menu-open time from a freeze.
#
# Measured 2026-09-21: Dan opened a card's genre dropdown and clicked away, and the log recorded 1.62s
# and 1.17s stalls whose stack sample has the main thread idle 95.5% with no Overture code running at
# all. The tool must name those rather than silently dropping them, because an exclusion would also hide
# a real freeze that happened while a menu was open (L116).
activity_record() { # seconds passes passSeconds activity  -> one ndjson line; "none" omits the activity
  local seconds="$1" passes="$2" cost="$3" activity="$4" tail=""
  [ "${activity}" != "none" ] && tail=",\"runLoopActivity\":\"${activity}\""
  printf '{"session":"s","sequence":1,"at":"2026-09-21T19:37:43Z","seconds":%s,"surface":"queue","load":"baseline","loadAverage":3.7,"passes":%s,"passSeconds":%s%s}\n' \
    "${seconds}" "${passes}" "${cost}" "${tail}"
}

# A log written before the field shipped, which is every record on Dan's Mac today. It must say it cannot
# tell menu-open time from a freeze, rather than implying none of it is (L98).
activity_record 1.62 0 0 none > "${WORK}/no-activity.ndjson"
activity_record 2.80 1 2.27 none >> "${WORK}/no-activity.ndjson"
out="$("${READER}" --log "${WORK}/no-activity.ndjson" 2>&1)"
assert_contains "a log with no run loop reading says it is unmeasured" "${out}" "run loop: UNMEASURED"
assert_contains "and names what that leaves unanswerable" "${out}" "may be menu-open time"

# Every record taken in the ordinary mode. A positive statement, never silence.
activity_record 2.80 1 2.27 ordinary > "${WORK}/activity-clean.ndjson"
activity_record 0.31 1 0.20 ordinary >> "${WORK}/activity-clean.ndjson"
out="$("${READER}" --log "${WORK}/activity-clean.ndjson" 2>&1)"
assert_contains "a log with no tracking in it says so positively" "${out}" "none was taken while a"
assert_not_contains "and does not accuse anything of being menu time" "${out}" "menu-open time rather than freezes"

# THE CASE THE ISSUE WAS OPENED FOR. A stall taken while a menu tracked, that ran no render pass and
# spent no time in one, is nested-loop time and must be named as such and kept out of the bar's maximum.
activity_record 1.62 0 0 tracking > "${WORK}/activity-menu.ndjson"
activity_record 2.80 1 2.27 ordinary >> "${WORK}/activity-menu.ndjson"
out="$("${READER}" --log "${WORK}/activity-menu.ndjson" 2>&1)"
assert_contains "a stall taken during menu tracking is named" "${out}" "while a menu was tracking"
assert_contains "and one that ran nothing is called menu-open time" "${out}" "menu-open time rather than freezes"
assert_contains "and the bar is told to be taken without it" "${out}" "must be taken without them"
assert_contains "and the worst one is named so it can be looked at" "${out}" "1.62s"

# THE OTHER HALF, and the one an exclusion would have destroyed. A stall taken while a menu was up that
# DID run render passes is a real freeze that happened to overlap a menu, and it stays in every
# population. Nothing here may drop it (L116).
activity_record 2.80 1 2.27 tracking > "${WORK}/activity-realfreeze.ndjson"
out="$("${READER}" --log "${WORK}/activity-realfreeze.ndjson" 2>&1)"
assert_contains "a nested stall that ran render passes is still a freeze" "${out}" "they are real freezes"
assert_contains "and it says they stay in every population" "${out}" "stay in every population"
assert_not_contains "and it is not counted as menu-open time" "${out}" "menu-open time rather than freezes"

# THE OVER-ACCUSATION THIS MUST NOT MAKE, and the reason it is a test rather than a comment. A probe on
# 2026-09-23 watched a sheet-presented NSAlert, which is what every `.alert` in this app becomes, and saw
# the main run loop pass through `_NSMoveTimerRunLoopMode` with nothing wrong. A tool that counted every
# mode it cannot name as menu time would accuse ordinary window work (L93), so an unnamed mode is
# reported as UNKNOWN and is kept out of the figure the bar is taken without.
activity_record 1.40 0 0 otherMode > "${WORK}/activity-other.ndjson"
out="$("${READER}" --log "${WORK}/activity-other.ndjson" 2>&1)"
assert_contains "an unnamed mode is reported" "${out}" "a run loop mode this build does not name"
assert_contains "and called unknown rather than menu time" "${out}" "is UNKNOWN"
assert_not_contains "and is not counted as menu-open time" "${out}" "menu-open time rather than freezes"
assert_not_contains "and the bar is not told to drop it" "${out}" "must be taken without them"

# The opposite reading: the main thread OFF the run loop entirely is the main thread in code, so those
# are freezes rather than contamination, and the tool must not lump them in with the nested modes.
activity_record 1.20 0 0 offTheRunLoop > "${WORK}/activity-off.ndjson"
activity_record 1.62 0 0 tracking >> "${WORK}/activity-off.ndjson"
out="$("${READER}" --log "${WORK}/activity-off.ndjson" 2>&1)"
assert_contains "a stall with the main thread off the run loop is named apart" "${out}" "OFF the run loop entirely"
assert_contains "and called a freeze rather than contamination" "${out}" "those are freezes"

# #4154: whether the MAIN THREAD was running while a stall lasted, which is what "no sample says why"
# needed. Reproduced 2026-09-25 against a clone of the live store: under CPU contention the pass took 5.45s
# with the main thread's own CPU clock at 23% of it and the kernel reporting it runnable, which is a thread
# other processes kept off the CPU. The record now carries both readings, and this tool has to name the
# three states apart and never fold an absent reading into any of them (L98).
thread_record() { # seconds cpu runnable waiting -> one ndjson line; "none" omits the field
  local tail=""
  [ "$2" != "none" ] && tail="${tail},\"mainThreadCPUSeconds\":$2"
  [ "$3" != "none" ] && tail="${tail},\"mainThreadRunnableSamples\":$3"
  [ "$4" != "none" ] && tail="${tail},\"mainThreadWaitingSamples\":$4"
  printf '{"session":"s","sequence":1,"at":"2026-09-22T15:24:00Z","seconds":%s,"surface":"queue","load":"elevated","loadAverage":34.7,"passes":1,"passSeconds":9.53,"asleepSeconds":0.0%s}\n' "$1" "${tail}"
}

thread_record 18.64 none none none > "${WORK}/thread-none.ndjson"
out="$("${READER}" --log "${WORK}/thread-none.ndjson" 2>&1)"
assert_contains "a log with no main thread reading says it is unmeasured" "${out}" "main thread: UNMEASURED"

{ thread_record 18.64 0.41 180 6      # starved: little CPU, runnable
  thread_record 15.98 0.33 150 4      # starved again, so the two states are different counts
  thread_record 6.20  0.05 2 58       # blocked: little CPU, waiting
  thread_record 3.10  2.90 30 1       # computing: CPU close to the duration
  thread_record 2.40  0.10 0 0        # not running, and no state sample to split it
} > "${WORK}/thread-mixed.ndjson"
out="$("${READER}" --log "${WORK}/thread-mixed.ndjson" 2>&1)"
assert_contains "the starved stalls are named as starved" "${out}" "2 STARVED"
assert_contains "and what starved means is said beside it" "${out}" "runnable and not scheduled"
assert_contains "the blocked stall is named apart" "${out}" "1 BLOCKED"
assert_contains "the computing stall is named apart" "${out}" "1 COMPUTING"
assert_contains "a stall with no state sample is not guessed at" "${out}" "1 not running unsplit"
assert_contains "the worst starved stall is quoted with its own CPU" "${out}" "18.64s with 0.41s on the CPU"
assert_contains "the table carries the main thread's share of each stall" "${out}" "asleep     cpu  surface"
assert_contains "and the starved stall's share is printed in it" "${out}" "      2%"

# A reading at the CPU without the state counts, or the reverse, is not a verdict either way.
thread_record 5.00 none 40 2 > "${WORK}/thread-half.ndjson"
out="$("${READER}" --log "${WORK}/thread-half.ndjson" 2>&1)"
assert_contains "state counts without a CPU reading are unmeasured, not starved" "${out}" "main thread: UNMEASURED"
assert_not_contains "and nothing is called starved" "${out}" "STARVED"

# #4188: the shared reader is refused BY NAME when it is missing. Without the check Python dies with a
# traceback and exit 1, which a caller of this script reads as a result rather than as nothing measured.
mkdir -p "${WORK}/nolib/scripts"
cp "${READER}" "${WORK}/nolib/scripts/"
printf '{"session":"s","sequence":1,"at":"2026-09-10T17:47:37Z","seconds":0.2,"load":"baseline"}\n' > "${WORK}/nolib/log.ndjson"
out="$("${WORK}/nolib/scripts/$(basename "${READER}")" --log "${WORK}/nolib/log.ndjson" 2>&1)"; status=$?
assert_equals "a missing shared reader is UNMEASURED, never a result" "2" "${status}"
assert_contains "and it names the file it could not find" "${out}" "freeze_records.py is missing"

if [ "${FAILURES}" -eq 0 ]; then
  echo "what-froze-the-queue.test.sh: all passed"
else
  echo "what-froze-the-queue.test.sh: ${FAILURES} failure(s)"
  exit 1
fi
