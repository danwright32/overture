#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"
# shellcheck source=../../../scripts/lib/fixture-process-leak.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts/lib/fixture-process-leak.sh"

# #3007: coverage for the per-request elapsed-time read.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./stuck-tool-call.sh
. "${HERE}/stuck-tool-call.sh"

WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${WORK}"' EXIT

# The shapes are copied from a REAL stream on this Mac (check-run-events.chunk-4.jsonl), not invented:
# an assistant message carrying a tool_use block, and a user message carrying the matching tool_result.
use_line() { printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"%s","name":"WebFetch"}]}}\n' "$1" "$2"; }
result_line() { printf '{"type":"user","timestamp":"%s","message":{"content":[{"type":"tool_result","tool_use_id":"%s"}]}}\n' "$1" "$2"; }
NOW=1780000000
at() { python3 -c "import datetime,sys; print(datetime.datetime.fromtimestamp(${NOW}-int(sys.argv[1]), datetime.UTC).strftime('%Y-%m-%dT%H:%M:%S.000Z'))" "$1"; }

# --- a call still in flight is measured from its own start ------------------------------------------
F="${WORK}/inflight.jsonl"
use_line "$(at 400)" "t1" > "${F}"
assert_equals "an in-flight call reports its own elapsed time" "400" "$(stuck_tool_call_seconds "${F}" "${NOW}")"

# --- a call that CAME BACK is not in flight, however long it took ------------------------------------
# The defect this exists for is a request that never returns. A slow one that finished is the ordinary
# case and must not be reported, or the watchdog fires on healthy work and is switched off (L93).
F="${WORK}/returned.jsonl"
{ use_line "$(at 400)" "t1"; result_line "$(at 390)" "t1"; } > "${F}"
assert_equals "a call that returned is not in flight" "0" "$(stuck_tool_call_seconds "${F}" "${NOW}")"

# --- the LONGEST one, when several are open ----------------------------------------------------------
F="${WORK}/several.jsonl"
{ use_line "$(at 30)" "t1"; use_line "$(at 400)" "t2"; use_line "$(at 5)" "t3"; } > "${F}"
assert_equals "the longest in-flight call is the one reported" "400" "$(stuck_tool_call_seconds "${F}" "${NOW}")"

# --- a healthy run reports a small number, not a refusal ---------------------------------------------
# Measured on this Mac across 357 real tool calls: WebFetch max 7.4s, WebSearch max 8.5s, nothing over
# 60s. A run mid-call is the ordinary state and must read as ordinary.
F="${WORK}/healthy.jsonl"
{ use_line "$(at 300)" "t1"; result_line "$(at 297)" "t1"; use_line "$(at 3)" "t2"; } > "${F}"
assert_equals "a run part way through a normal call reads as seconds" "3" "$(stuck_tool_call_seconds "${F}" "${NOW}")"

# --- "cannot tell" is its own answer, never zero -----------------------------------------------------
# Zero means "nothing is stuck", which is a claim. A missing file, a missing node, or a stream with
# nothing parsable in it are all "I did not look", and folding them into zero is how a watchdog reports
# health for a run it never examined (L98, L11).
assert_equals "a missing events file cannot tell" "-1" "$(stuck_tool_call_seconds "${WORK}/nope.jsonl" "${NOW}")"

F="${WORK}/garbage.jsonl"
printf 'not json at all\nnor this\n' > "${F}"
assert_equals "a stream with nothing parsable cannot tell" "-1" "$(stuck_tool_call_seconds "${F}" "${NOW}")"

F="${WORK}/empty.jsonl"
: > "${F}"
assert_equals "an empty stream cannot tell" "-1" "$(stuck_tool_call_seconds "${F}" "${NOW}")"

# A stream being APPENDED to while this reads it ends in a partial line. That is the ordinary case, not a
# broken file, so it is skipped and the rest is still read.
F="${WORK}/partial.jsonl"
{ use_line "$(at 400)" "t1"; printf '{"type":"assis'; } > "${F}"
assert_equals "a half-written last line does not stop the read" "400" "$(stuck_tool_call_seconds "${F}" "${NOW}")"

# --- it works on a REAL stream from this Mac, when there is one --------------------------------------
# A fixture can only ever confirm my own assumption about the shape (L52). The real archives are the only
# thing that can say the shape is right, so they are read when present and skipped, loudly, when not.
REAL="${HOME}/Library/Application Support/Overture/check-run-events.chunk-4.jsonl"
if [[ -f "${REAL}" ]]; then
  # Every call in a FINISHED run has returned, so nothing is in flight and the answer is 0, never -1:
  # a completed stream is readable and has nothing open in it.
  assert_equals "a finished real run has no call in flight" "0" \
    "$(stuck_tool_call_seconds "${REAL}" "${NOW}")"
else
  echo "ok - no real events file on this machine, so the real-shape check was SKIPPED (not passed)"
fi

# --- the watchdog loop: it kills the ONE stuck chunk and leaves the others ---------------------------
#
# Driven as real processes, because what is under test is a kill: whether the right pid dies and the
# others do not. A source assertion cannot see that.
WD="${WORK}/wd"
mkdir -p "${WD}"
# The loop asks `slot_chunk_events`, which belongs to the run-slot lib. Stubbed here so this fixture
# needs no slot, no support directory and no run.
slot_chunk_events() { echo "${WD}/events-$1.jsonl"; }

STUCK_TOOL_CALL_LIMIT=60
STUCK_TOOL_CALL_POLL=1

# The REAL clock here, not the pinned one the reads above use. The watchdog takes its own `date +%s`, so
# a fixture timestamped against a pinned epoch would measure the gap between that epoch and today and
# report every chunk as stuck. It did, on the first run: 7,359,997s. A fixture whose meaning is the
# relationship between a stored time and the clock has to pin BOTH ends or use neither (L130, L134).
at_real() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.UTC)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%S.000Z'))" "$1"; }

# Chunk 1 is mid-call and healthy; chunk 2 has been on one request for 400s.
use_line "$(at_real 3)"   "a1" > "${WD}/events-1.jsonl"
use_line "$(at_real 400)" "b1" > "${WD}/events-2.jsonl"

# The whole scenario runs in a SUBSHELL with its stderr redirected, and hands its answers back in files.
# That is not tidiness: a shell reports a job it killed to ITS OWN stderr at the next command boundary,
# and redirecting a group or a command inside the shell does not cover that, so P2 (killed by the
# watchdog) rendered `Terminated: 15  sleep 120` into the runner's log every run. A subshell's notices go
# to the subshell's stderr, which a redirection can reach. Same subject as #2981, met in a fixture.
OUT_FILE="${WORK}/wd.out"
(
  sleep 120 & P1=$!
  sleep 120 & P2=$!
  set -m
  ( stuck_watchdog_run 2 "${P1} ${P2}" > "${OUT_FILE}" 2>&1 ) & WD_PID=$!
  set +m
  # Two polls' worth, so a loop that never ticks fails rather than passing on a race.
  sleep 3
  kill "${WD_PID}" 2>/dev/null || true
  wait "${WD_PID}" 2>/dev/null || true
  # #3254: and the `sleep` INSIDE the watchdog subshell, which the kill above does not reach. The
  # watchdog polls with `sleep "$STUCK_TOOL_CALL_POLL"`, so killing its wrapper leaves that sleep
  # running as an orphan, one per case, every sweep. This is the same defect the fixture is testing
  # for one field over (L321).
  fixture_end_process_group "${WD_PID}"
  # Both read BEFORE either is reaped, so the answers are honest.
  kill -0 "${P2}" 2>/dev/null && echo 1 > "${WORK}/p2.alive" || echo 0 > "${WORK}/p2.alive"
  kill -0 "${P1}" 2>/dev/null && echo 1 > "${WORK}/p1.alive" || echo 0 > "${WORK}/p1.alive"
  kill "${P1}" 2>/dev/null || true
  wait 2>/dev/null || true
) 2>/dev/null

assert_equals "the stuck chunk is killed" "0" "$(cat "${WORK}/p2.alive")"
# The positive control, and the one that matters: a watchdog that killed everything would pass the line
# above while being far worse than no watchdog at all.
assert_equals "the healthy chunk is left alone" "1" "$(cat "${WORK}/p1.alive")"
assert_contains "and it says which chunk and why" "$(cat "${OUT_FILE}")" "STOPPING CHUNK 2"
assert_contains "naming the elapsed time it measured" "$(cat "${OUT_FILE}")" "in flight for 40"
assert_not_contains "and never names the healthy one" "$(cat "${OUT_FILE}")" "STOPPING CHUNK 1"

# --- a stream it cannot read is SAID, once, and nothing is killed -------------------------------------
# Silence would be indistinguishable from a watchdog that is working (L98); repeating it every poll is
# how a real warning gets scrolled past (L36).
rm -f "${WD}/events-1.jsonl"
OUT_FILE="${WORK}/wd2.out"
(
  sleep 120 & P3=$!
  set -m
  ( stuck_watchdog_run 1 "${P3}" > "${OUT_FILE}" 2>&1 ) & WD_PID=$!
  set +m
  sleep 4
  kill "${WD_PID}" 2>/dev/null || true
  wait "${WD_PID}" 2>/dev/null || true
  # #3254: and the `sleep` INSIDE the watchdog subshell, which the kill above does not reach. The
  # watchdog polls with `sleep "$STUCK_TOOL_CALL_POLL"`, so killing its wrapper leaves that sleep
  # running as an orphan, one per case, every sweep. This is the same defect the fixture is testing
  # for one field over (L321).
  fixture_end_process_group "${WD_PID}"
  kill -0 "${P3}" 2>/dev/null && echo 1 > "${WORK}/p3.alive" || echo 0 > "${WORK}/p3.alive"
  kill "${P3}" 2>/dev/null || true
  wait 2>/dev/null || true
) 2>/dev/null

assert_equals "an unreadable stream kills nothing" "1" "$(cat "${WORK}/p3.alive")"
assert_contains "and says so" "$(cat "${OUT_FILE}")" "could not read chunk 1"
assert_equals "exactly once, over several polls" "1" \
  "$(grep -c "could not read chunk 1" "${OUT_FILE}")"

# --- the limit is far outside the measured distribution ----------------------------------------------
# 357 real tool calls on this Mac: WebFetch max 7.4s, WebSearch max 8.5s, nothing over 60s. A threshold
# sitting inside the dense part of a real distribution turns its count into noise (L172), so this pins
# that the default is nowhere near it.
SRC="$(cat "${HERE}/stuck-tool-call.sh")"
DEFAULT="$(printf '%s' "${SRC}" | sed -n 's/.*OVERTURE_STUCK_TOOL_CALL_LIMIT_SECONDS:-\([0-9]*\)}.*/\1/p')"
assert_equals "the default limit is at least ten times the slowest call ever recorded here" "1" \
  "$([ -n "${DEFAULT}" ] && [ "${DEFAULT}" -ge 90 ] && echo 1 || echo 0)"
assert_equals "and well under the run-level stop that used to be the only thing that ended one" "1" \
  "$([ -n "${DEFAULT}" ] && [ "${DEFAULT}" -lt 1200 ] && echo 1 || echo 0)"

# --- a non-numeric answer is folded to "cannot tell", never to a comparison (L50) --------------------
# `[ "$x" -ge n ]` on a non-numeric or EMPTY value is not false, it is an ERROR, and the loop runs under
# the runner's `set -e`. One unexpected byte on stdout would kill the watchdog silently, leaving a run
# with no per-request cap while everything looked fine. The fail-safe side is to decline to kill.
stuck_tool_call_seconds() { echo "not a number"; }
sleep 120 & P4=$!
OUT_FILE="${WORK}/wd3.out"
(
  set -m
  ( stuck_watchdog_run 1 "${P4}" > "${OUT_FILE}" 2>&1 ) & WD_PID=$!
  set +m
  sleep 3
  kill "${WD_PID}" 2>/dev/null || true
  wait "${WD_PID}" 2>/dev/null || true
  # #3254: and the `sleep` INSIDE the watchdog subshell, which the kill above does not reach. The
  # watchdog polls with `sleep "$STUCK_TOOL_CALL_POLL"`, so killing its wrapper leaves that sleep
  # running as an orphan, one per case, every sweep. This is the same defect the fixture is testing
  # for one field over (L321).
  fixture_end_process_group "${WD_PID}"
  kill -0 "${P4}" 2>/dev/null && echo 1 > "${WORK}/p4.alive" || echo 0 > "${WORK}/p4.alive"
  kill "${P4}" 2>/dev/null || true
  wait 2>/dev/null || true
) 2>/dev/null
assert_equals "a nonsense answer kills nothing" "1" "$(cat "${WORK}/p4.alive")"
assert_contains "and is reported as unreadable rather than swallowed" "$(cat "${OUT_FILE}")" "could not read"

stuck_tool_call_seconds() { echo ""; }
sleep 120 & P5=$!
OUT_FILE="${WORK}/wd4.out"
(
  set -m
  ( stuck_watchdog_run 1 "${P5}" > "${OUT_FILE}" 2>&1 ) & WD_PID=$!
  set +m
  sleep 3
  kill "${WD_PID}" 2>/dev/null || true
  wait "${WD_PID}" 2>/dev/null || true
  # #3254: and the `sleep` INSIDE the watchdog subshell, which the kill above does not reach. The
  # watchdog polls with `sleep "$STUCK_TOOL_CALL_POLL"`, so killing its wrapper leaves that sleep
  # running as an orphan, one per case, every sweep. This is the same defect the fixture is testing
  # for one field over (L321).
  fixture_end_process_group "${WD_PID}"
  kill -0 "${P5}" 2>/dev/null && echo 1 > "${WORK}/p5.alive" || echo 0 > "${WORK}/p5.alive"
  kill "${P5}" 2>/dev/null || true
  wait 2>/dev/null || true
) 2>/dev/null
assert_equals "an EMPTY answer kills nothing either" "1" "$(cat "${WORK}/p5.alive")"
assert_contains "and says so" "$(cat "${OUT_FILE}")" "could not read"

if [[ "${FAILURES:-0}" -ne 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all stuck-tool-call.sh checks passed"
