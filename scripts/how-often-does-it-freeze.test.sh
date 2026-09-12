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

if [ "${FAILURES}" -eq 0 ]; then
  echo "how-often-does-it-freeze.test.sh: all passed"
else
  echo "how-often-does-it-freeze.test.sh: ${FAILURES} failure(s)"
  exit 1
fi
