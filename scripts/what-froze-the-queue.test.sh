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

if [ "${FAILURES}" -eq 0 ]; then
  echo "what-froze-the-queue.test.sh: all passed"
else
  echo "what-froze-the-queue.test.sh: ${FAILURES} failure(s)"
  exit 1
fi
