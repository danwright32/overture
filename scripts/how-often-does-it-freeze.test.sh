#!/usr/bin/env bash
set -uo pipefail

# #3660: the judging half of scripts/how-often-does-it-freeze.sh, driven against built logs rather than
# the live one, so every outcome can be PRODUCED rather than waited for.
#
# The outcomes that matter are the UNMEASURED ones. A log with nothing comparable in it and a log showing
# a quiet week both leave this script with no rate to print, and folding them together would make the
# emptiest possible failure read as the cleanest possible answer (L98, L11). The tool exists to feed a
# milestone bar, which is exactly where a reassuring blank is most expensive.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER="${SCRIPT_DIR}/how-often-does-it-freeze.sh"
FAILURES=0

WORK="$(fixture_scratch_dir)"
MAIN_SHELL_PID="${BASHPID:-$$}"
trap '[ "${BASHPID:-$$}" = "${MAIN_SHELL_PID}" ] && rm -rf "${WORK}"' EXIT

# session sequence seconds load -> one ndjson line
record() {
  printf '{"session":"%s","sequence":%s,"at":"2026-09-11T18:47:20Z","seconds":%s,"surface":"queue","load":"%s","loadAverage":3.7,"passes":1}\n' \
    "$1" "$2" "$3" "$4"
}

# 1. No log at all is UNMEASURED, never a clean bill.
out="$("${READER}" --log "${WORK}/absent.ndjson" 2>&1)"; status=$?
assert_equals "a missing log is UNMEASURED" "2" "${status}"
assert_contains "and it says so rather than reporting no freezes" "${out}" "UNMEASURED"

# 2. A log that exists and holds nothing is a different fact from one that is missing, and also
#    UNMEASURED rather than a session with no stalls.
: > "${WORK}/empty.ndjson"
out="$("${READER}" --log "${WORK}/empty.ndjson" 2>&1)"; status=$?
assert_equals "an empty log is UNMEASURED" "2" "${status}"

# 3. Only sessions from before #3752, when the floor was 250 ms. Those cannot be compared with a reading
#    taken now: a coarser floor does not give a smaller number of stalls, it gives a number of LARGER
#    ones, and pooling the two would compare a period that could not see a 150 ms stall with one that
#    could (L216).
mkdir -p "${WORK}/old"
{ record old 1000 0.400 baseline; record old 2000 0.900 baseline; } > "${WORK}/old/log.ndjson"
out="$("${READER}" --log "${WORK}/old/log.ndjson" 2>&1)"; status=$?
assert_equals "a log with nothing at the current floor is UNMEASURED" "2" "${status}"
assert_contains "and it names the floor as the reason, not the stall count" "${out}" "UNKNOWN floor"

# 4. At the current floor, but every record taken while the machine was busy. The bar is about a quiet
#    machine, so there is nothing here to judge it by, and saying nothing would read as meeting it.
mkdir -p "${WORK}/busy"
{ record busy 1000 0.150 elevated; record busy 2000 0.900 elevated; } > "${WORK}/busy/log.ndjson"
out="$("${READER}" --log "${WORK}/busy/log.ndjson" 2>&1)"; status=$?
assert_equals "a log with no baseline load records is UNMEASURED" "2" "${status}"
assert_contains "and it says which half is missing" "${out}" "baseline load"

# 5. A real reading. 36,000 pings at 0.1s is one hour watched, so the rate is arithmetic a reader can
#    check by eye rather than a number only this script can produce.
mkdir -p "${WORK}/real"
{ record live 100 0.150 baseline
  record live 200 0.400 baseline
  record live 36000 0.900 baseline; } > "${WORK}/real/log.ndjson"
out="$("${READER}" --log "${WORK}/real/log.ndjson" 2>&1)"; status=$?
assert_equals "a log with a comparable population reports" "0" "${status}"
assert_contains "and it states the watched time it divided by" "${out}" "1.00h watched"
assert_contains "and the rate is per hour, three stalls in one hour" "${out}" "3.0 per hour"
assert_contains "and it refuses to read the count as a proportion over the bar" "${out}" "never as a proportion"

# 6. A session sitting exactly on the write cap stopped WRITING rather than went quiet (#3812). A reading
#    that did not say so would be computed over the first 200 stalls of that session while looking
#    exactly like a reading of all of them.
mkdir -p "${WORK}/capped"
{ for i in $(seq 1 200); do record capped "$((i * 10))" 0.150 baseline; done; } > "${WORK}/capped/log.ndjson"
out="$("${READER}" --log "${WORK}/capped/log.ndjson" 2>&1)"; status=$?
assert_equals "a censored session still reports" "0" "${status}"
assert_contains "and it says the figures are understated" "${out}" "UNDERSTATED"
assert_contains "and it names the issue rather than describing a coincidence" "${out}" "#3812"
# #3812's fix makes a session at the cap AMBIGUOUS rather than censored: a build carrying it writes every
# stall, so exactly 200 there is an ordinary count, and nothing in a record says which build wrote it. A
# reader that went on asserting censorship would be claiming something it cannot measure (L11, L440).
assert_contains "and it says the two readings cannot be told apart" "${out}" "cannot be told"
assert_not_contains "and it no longer says the write still stops there" "${out}" "stops a session writing"

# 7. A session one record short of the cap is NOT censored, which is the other half: a warning that
#    fires on every session says nothing, and one that fires on none is the defect it exists to catch
#    (L159).
mkdir -p "${WORK}/uncapped"
{ for i in $(seq 1 199); do record uncapped "$((i * 10))" 0.150 baseline; done; } > "${WORK}/uncapped/log.ndjson"
out="$("${READER}" --log "${WORK}/uncapped/log.ndjson" 2>&1)"; status=$?
assert_equals "a session under the cap reports" "0" "${status}"
assert_not_contains "and is not accused of being censored" "${out}" "UNDERSTATED"

# 8. The archive beside the log is part of the population. A reader that opened only the live file would
#    report on the recent window while looking exactly like a reader of the whole history.
mkdir -p "${WORK}/with-archive"
{ record live 100 0.150 baseline; record live 36000 0.400 baseline; } > "${WORK}/with-archive/log.ndjson"
{ record older 100 0.120 baseline; record older 36000 0.500 baseline; } > "${WORK}/with-archive/freeze-log-archive.ndjson"
out="$("${READER}" --log "${WORK}/with-archive/log.ndjson" 2>&1)"; status=$?
assert_equals "a log with an archive beside it reports" "0" "${status}"
assert_contains "and the archived records are in the population" "${out}" "4 record(s) over 2 sessions"
assert_contains "and it names the archive it read, so one file cannot pass for two" \
  "${out}" "freeze-log-archive.ndjson"

# 9. #4188: the records that are NOT freezes, and the three states that must stay apart. Until #4188 this
#    reader took each record's `seconds` and nothing else, so a Mac asleep for 1,057.90s (#4153) and a
#    stall taken while a menu was tracking with no render pass run (#4114) were both counted as freezes by
#    the one tool whose job is counting them, while scripts/what-froze-the-queue.sh had been taught both.
#    Marked, never dropped: the count is stated WITH and WITHOUT them. And a record carrying neither field
#    is a third state, UNMEASURED, never folded into either of the others (absent is not zero, L98).
#
# full_record session sequence seconds asleep activity passes passSeconds -> one line; "none" omits the field
full_record() {
  local tail=""
  [ "$4" != "none" ] && tail="${tail},\"asleepSeconds\":$4"
  [ "$5" != "none" ] && tail="${tail},\"runLoopActivity\":\"$5\""
  printf '{"session":"%s","sequence":%s,"at":"2026-09-22T03:07:14Z","seconds":%s,"surface":"queue","load":"baseline","loadAverage":3.7,"passes":%s,"passSeconds":%s%s}\n' \
    "$1" "$2" "$3" "$6" "$7" "${tail}"
}
mkdir -p "${WORK}/mixed"
{ full_record mixed 100   0.150   0      ordinary 1 0.10        # a freeze, both fields present
  full_record mixed 200   1057.90 1074.0 ordinary 0 0.0         # the sleeping Mac: not a freeze
  full_record mixed 300   1.62    0      tracking 0 0.0         # a menu tracking, nothing ran: not a freeze
  full_record mixed 400   2.50    0      tracking 3 1.90        # a menu tracking WITH render time: a freeze
  full_record mixed 36000 0.400   none   none     1 0.20        # neither field: UNMEASURED
  printf '{"note":"compaction","at":"2026-09-21T21:05:00Z","kept":5,"archived":0,"promotedAt":null,"promotedSeconds":null}\n'
} > "${WORK}/mixed/log.ndjson"
out="$("${READER}" --log "${WORK}/mixed/log.ndjson" 2>&1)"; status=$?
assert_equals "a log holding records that are not freezes still reports" "0" "${status}"
assert_contains "the compaction note is not a stall (#4122)" "${out}" "5 record(s) over 1 session."
assert_contains "the count with every record is stated and labelled" "${out}" "every record:  n=5"
assert_contains "and the maximum with every record is the sleep, said where it is quoted" "${out}" "max 1057.900s"
assert_contains "the count without the records that are not freezes is stated beside it" "${out}" \
  "without the 2 that are not freezes:  n=3"
assert_contains "and its maximum is the real freeze that overlapped a menu" "${out}" "p99 2.500s   max 2.500s"
assert_contains "the sleep is named as a reason, with its issue" "${out}" "1 spanned a sleep (#4153)"
assert_contains "the idle menu record is named as a reason, with its issue" "${out}" \
  "1 was taken while a menu tracked and ran no render pass (#4114)"
assert_contains "a record carrying neither field is UNMEASURED, not a freeze and not excluded" "${out}" \
  "1 of the 5 cannot be judged"
assert_contains "and it says which field each one lacks" "${out}" "1 carry no sleep reading, 1 no run loop reading"

# 10. The UNMEASURED state alone. A log written before #4153 and #4114 must not print a "without" line
#     that reads as a measured exclusion of nothing: nothing was measured, so it says that instead.
mkdir -p "${WORK}/unjudged"
{ record unjudged 100 0.150 baseline; record unjudged 36000 0.400 baseline; } > "${WORK}/unjudged/log.ndjson"
out="$("${READER}" --log "${WORK}/unjudged/log.ndjson" 2>&1)"; status=$?
assert_equals "a log with neither field still reports its rate" "0" "${status}"
assert_contains "and says none of it could be judged" "${out}" "2 of the 2 cannot be judged"
assert_not_contains "and prints no without-line pretending the exclusion was measured" "${out}" "that are not freezes:"

# 11. Both fields present and neither says not-a-freeze: every record is a freeze, and it says so rather
#     than printing nothing, because silence here is indistinguishable from the unmeasured case above.
mkdir -p "${WORK}/allfreeze"
{ full_record allf 100 0.150 0 ordinary 1 0.1; full_record allf 36000 0.400 0 offTheRunLoop 0 0.0; } \
  > "${WORK}/allfreeze/log.ndjson"
out="$("${READER}" --log "${WORK}/allfreeze/log.ndjson" 2>&1)"; status=$?
assert_equals "a log of measured freezes reports" "0" "${status}"
assert_contains "and says none of them is anything but a freeze" "${out}" "none of the 2 is shown not to be a freeze"
assert_not_contains "and does not call any of them unjudged" "${out}" "cannot be judged"

# 12. The per session table carries the same split, so a session's stalled share is not a sleep.
assert_contains "the table has the not-a-freeze column" "${out}" "not freezes"

# 13. `notRecorded` is how the app SPELLS an absent run loop reading (every record where nothing was
#     sampled), so it is unmeasured exactly as a missing key is, never a reading that says "freeze".
mkdir -p "${WORK}/notrecorded"
{ full_record nr 100 0.150 0 notRecorded 1 0.1; full_record nr 36000 0.400 0 ordinary 1 0.1; } \
  > "${WORK}/notrecorded/log.ndjson"
out="$("${READER}" --log "${WORK}/notrecorded/log.ndjson" 2>&1)"
assert_contains "a notRecorded run loop is unjudged, and named as the field it lacks" "${out}" \
  "1 of the 2 cannot be judged: 0 carry no sleep reading, 1 no run loop reading."

# #4188: the shared reader is refused BY NAME when it is missing. Without the check Python dies with a
# traceback and exit 1, which a caller of this script reads as a result rather than as nothing measured.
mkdir -p "${WORK}/nolib/scripts"
cp "${READER}" "${WORK}/nolib/scripts/"
printf '{"session":"s","sequence":1,"at":"2026-09-10T17:47:37Z","seconds":0.2,"load":"baseline"}\n' > "${WORK}/nolib/log.ndjson"
out="$("${WORK}/nolib/scripts/$(basename "${READER}")" --log "${WORK}/nolib/log.ndjson" 2>&1)"; status=$?
assert_equals "a missing shared reader is UNMEASURED, never a result" "2" "${status}"
assert_contains "and it names the file it could not find" "${out}" "freeze_records.py is missing"

if [ "${FAILURES}" -eq 0 ]; then
  echo "how-often-does-it-freeze.test.sh: all passed"
else
  echo "how-often-does-it-freeze.test.sh: ${FAILURES} failure(s)"
  exit 1
fi
