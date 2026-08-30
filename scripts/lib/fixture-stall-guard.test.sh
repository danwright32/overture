#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=./shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shell-assertions.sh"
# shellcheck source=./fixture-stall-guard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixture-stall-guard.sh"

# #2929: the shell fixture runner had no stall guard, so a fixture that never returns left it silent
# forever, and a silent runner is indistinguishable from one still working.
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PROGRESS="${WORK}/progress"

# --- what counts as progress -------------------------------------------------------------------------
# A fixture STARTING counts, not only one finishing. With eight lanes, counting only finishes would let
# seven fast lanes mask one hung fixture for as long as work remained.
printf 'started scripts/a.test.sh\n' > "${PROGRESS}"
assert_equals "a fixture starting is progress" "1" "$(fixture_progress_count "${PROGRESS}")"
printf 'finished scripts/a.test.sh\n' >> "${PROGRESS}"
assert_equals "and so is one finishing" "2" "$(fixture_progress_count "${PROGRESS}")"

# Output a FIXTURE happens to print is not progress. That distinction is the whole guard: the Swift
# incident it is modelled on wrote 21MB standing still, so anything counting bytes reports a healthy run.
printf 'ok - something a fixture printed\nFAIL - and something else\n' >> "${PROGRESS}"
assert_equals "a fixture's own output is not progress" "2" "$(fixture_progress_count "${PROGRESS}")"

# A progress file that is not there answers zero rather than failing: the watcher starts before the
# runner has written anything.
assert_equals "a missing progress file counts zero" "0" "$(fixture_progress_count "${WORK}/nope")"

# --- which fixtures are still going ------------------------------------------------------------------
# Named in the warning, because the name is the only part anybody can act on.
printf 'started scripts/a.test.sh\nstarted scripts/b.test.sh\nfinished scripts/a.test.sh\n' > "${PROGRESS}"
assert_equals "the one that started and never finished is named" \
  "scripts/b.test.sh" "$(fixture_still_running "${PROGRESS}")"

printf 'started scripts/a.test.sh\nfinished scripts/a.test.sh\n' > "${PROGRESS}"
assert_empty "and nothing is named when they all finished" "$(fixture_still_running "${PROGRESS}")"

# --- the warning itself ------------------------------------------------------------------------------
WARNING="$(fixture_stall_warning 300 "40 progress lines" "scripts/b.test.sh")"
assert_contains "says how long the silence has lasted" "${WARNING}" "5m"
assert_contains "and names what is still running" "${WARNING}" "scripts/b.test.sh"
assert_contains "and says it is a hang rather than a queue" "${WARNING}" "hang rather than a queue"
# It must not borrow the Swift runner's reason. There is no shared lock and no build phase here, so a
# message about either would claim something its check never measured (L11). Asserted on the Swift
# runner's own words rather than on the word "lock", which this message uses to say there ISN'T one.
assert_not_contains "it never says this run is queued" "${WARNING}" "STILL WAITING"
assert_not_contains "and never blames xcodebuild" "${WARNING}" "xcodebuild"

RESUMED="$(fixture_progress_resumed_notice 300)"
assert_contains "a false alarm says so" "${RESUMED}" "false alarm"
assert_contains "and names the knob rather than teaching the reader to ignore it" \
  "${RESUMED}" "OVERTURE_FIXTURE_STALL_LIMIT_SECONDS"

# --- the loop, driven for real ------------------------------------------------------------------------
# The whole guard, end to end: a progress file that stops moving must produce the warning, and one that
# keeps moving must not. Driven with a one second cadence rather than by reading the source, because a
# loop that never fires reads exactly like one whose condition is right (L1).
printf 'started scripts/a.test.sh\n' > "${PROGRESS}"
OUT="${WORK}/watch.err"
( fixture_watch_loop "${PROGRESS}" 2 1 2>"${OUT}" ) &
LOOP=$!
sleep 5
kill "${LOOP}" 2>/dev/null || true
CHILDREN="$(pgrep -P "${LOOP}" 2>/dev/null || true)"
[[ -n "${CHILDREN}" ]] && kill ${CHILDREN} 2>/dev/null
wait "${LOOP}" 2>/dev/null || true
assert_contains "a file that stops moving produces the warning" "$(cat "${OUT}")" "NO FIXTURE HAS STARTED OR FINISHED"
assert_contains "and the warning names the fixture still running" "$(cat "${OUT}")" "scripts/a.test.sh"

# The other direction, which is what keeps it from being a guard that fires on everything (L93).
printf 'started scripts/a.test.sh\n' > "${PROGRESS}"
OUT2="${WORK}/watch2.err"
( fixture_watch_loop "${PROGRESS}" 2 1 2>"${OUT2}" ) &
LOOP2=$!
for i in 1 2 3 4 5 6; do
  printf 'finished scripts/%s.test.sh\nstarted scripts/%s-next.test.sh\n' "${i}" "${i}" >> "${PROGRESS}"
  sleep 1
done
kill "${LOOP2}" 2>/dev/null || true
CHILDREN2="$(pgrep -P "${LOOP2}" 2>/dev/null || true)"
[[ -n "${CHILDREN2}" ]] && kill ${CHILDREN2} 2>/dev/null
wait "${LOOP2}" 2>/dev/null || true
assert_not_contains "a run that keeps moving is never warned about" "$(cat "${OUT2}")" "NO FIXTURE HAS"

# No cadence is no watcher, rather than a loop spinning as fast as the machine allows.
fixture_watch_loop "${PROGRESS}" 2 0
assert_equals "a zero interval returns instead of spinning" "0" "$?"

# --- starting and stopping the watcher whole (#3248) ---------------------------------------------------
#
# Everything above drives the LOOP directly and says nothing about the pair that ships. The loop spends
# almost all its life inside `sleep`, and killing it does not take that child with it: it is reparented
# to launchd, runs out its full interval, and holds the runner's stdout open the whole time, so anything
# capturing that output waits for it (#2577 measured this on the Swift side). The twin of this pair in
# mac/scripts/lib/test-progress-watch.sh had the same defect and the same fix.
OVERTURE_FIXTURE_STALL_CHECK_SECONDS=30 FIXTURE_STALL_CHECK_SECONDS=30 start_fixture_watch "${PROGRESS}"
WATCH_PID="${FIXTURE_WATCH_PID}"
assert_equals "starting a watcher records a PID to stop it by" \
  "recorded" "$(if [[ -n "${WATCH_PID}" ]]; then echo recorded; else echo empty; fi)"

WATCH_PGID="$(ps -o pgid= -p "${WATCH_PID}" 2>/dev/null | tr -d ' ')"
SHELL_PGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
assert_equals "the watcher leads a process group of its own" "${WATCH_PID}" "${WATCH_PGID}"
assert_equals "which is not this run's own group, so stopping it cannot take the run with it" \
  "different" \
  "$(if [[ "${WATCH_PGID}" != "${SHELL_PGID}" ]]; then echo "different"; else echo "the same: ${WATCH_PGID}"; fi)"

# Waited ON rather than waited OUT, for the reason this whole change is about (L290): a fixed delay
# here asserts how busy the Mac is, and the ordinary case clears on the first look.
WAITED=0
WATCH_CHILDREN=""
while [[ -z "${WATCH_CHILDREN// /}" && "${WAITED}" -lt 200 ]]; do
  WATCH_CHILDREN="$(pgrep -P "${WATCH_PID}" 2>/dev/null | tr '\n' ' ')"
  [[ -n "${WATCH_CHILDREN// /}" ]] && break
  sleep 0.05
  WAITED=$((WAITED + 1))
done
# Asserted before the stop, because everything after it is vacuous if there was no sleeping child to
# leave behind (L159).
assert_equals "a watcher mid-interval really does have a sleeping child to leave behind" \
  "has children" \
  "$(if [[ -n "${WATCH_CHILDREN// /}" ]]; then echo "has children"; else echo "none, so nothing below is proved"; fi)"

STOP_STARTED_AT="${SECONDS}"
stop_fixture_watch "${WATCH_PID}"
STOP_TOOK=$(( SECONDS - STOP_STARTED_AT ))
assert_equals "stopping it does not wait out its 30 second interval" \
  "prompt" \
  "$(if [[ "${STOP_TOOK}" -le 5 ]]; then echo "prompt"; else echo "took ${STOP_TOOK}s"; fi)"
# shellcheck disable=SC2086
assert_pids_gone "and it leaves neither the loop nor its sleeping child behind" \
  "${WATCH_PID}" ${WATCH_CHILDREN}

# Called from the normal path AND from an EXIT trap, so a second call is the ordinary case rather than
# an error, and neither it nor an empty pid may take the run down under `set -e`.
stop_fixture_watch "${WATCH_PID}"
assert_equals "stopping it twice is safe, which is what the EXIT trap does" "0" "$?"
stop_fixture_watch ""
assert_equals "and stopping a watcher that was never started is safe too" "0" "$?"

if [[ "${FAILURES:-0}" -ne 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all fixture-stall-guard checks passed"
