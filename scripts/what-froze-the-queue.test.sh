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

record() { # seconds passes  -> one ndjson line, passes omitted entirely when "none"
  local seconds="$1" passes="$2" tail=""
  [ "${passes}" != "none" ] && tail=",\"passes\":${passes}"
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

# 4. A stall that spanned NO pass. This is the finding: the surface did not rebuild, so the freeze is
#    something other than the render pass and the next diagnosis goes elsewhere.
record 16.73 0 > "${WORK}/unexplained.ndjson"
record 0.31 2 >> "${WORK}/unexplained.ndjson"
out="$("${READER}" --log "${WORK}/unexplained.ndjson" 2>&1)"; status=$?
assert_equals "a stall spanning no pass is something to look at" "1" "${status}"
assert_contains "and it says the surface did not rebuild" "${out}" "did not rebuild"

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

if [ "${FAILURES}" -eq 0 ]; then
  echo "what-froze-the-queue.test.sh: all passed"
else
  echo "what-froze-the-queue.test.sh: ${FAILURES} failure(s)"
  exit 1
fi
