#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains, assert_equals,
# assert_eq, assert_empty (#2501). Haystack second, needle third.
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"

# #2763 (phase 1 of #2620): the runner reads which slot it is, and every path it touches comes from that.
#
# The two halves that matter are the lenient default and the loud refusal, and they are different facts.
# An old app that names no slot means the run it has always launched: the runner script is not in the app
# bundle, it is resolved from a UserDefaults path into the git checkout, and update-overture.sh
# fast-forwards the checkout BEFORE the 90 second rebuild, so a new script routinely meets an old app. A
# value nobody recognises is the opposite: the two halves disagree about what a slot IS, and guessing
# there is how one run comes to write another run's files.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
# A SPACE in the path, because the live one has one: "~/Library/Application Support/Overture". A fixture
# on a tidy path cannot see the whole class of defect where an unquoted expansion word-splits, and the
# wipe below is exactly that shape.
SUPPORT_DIR="${WORK}/Application Support/Overture"
mkdir -p "${SUPPORT_DIR}"

# Sourced with SUPPORT already set, exactly as prep-run.sh sources it. In a subshell so a refusal's exit
# ends the resolver rather than this fixture.
run_resolver() {
  (
    SUPPORT="${SUPPORT_DIR}"
    . "${HERE}/run-slot.sh"
    resolve_run_slot
    echo "SLOT=${RUN_SLOT}"
    echo "QUEUE=$(basename "${SLOT_QUEUE}")"
    echo "RESULTS=$(basename "${SLOT_RESULTS}")"
    echo "PROGRESS=$(basename "${SLOT_PROGRESS}")"
    echo "MARKER=$(basename "${SLOT_MARKER}")"
    echo "CANCEL=$(basename "${SLOT_CANCEL}")"
    echo "CHUNKDIR=$(basename "${SLOT_CHUNKDIR}")"
    echo "PIDFILE=$(basename "${SLOT_CLAUDE_PID}")"
    echo "STALL=$(basename "${SLOT_STALL_STATE}")"
    echo "LOG=${SLOT_LOG_NAME}"
    echo "EVENTS=$(basename "${SLOT_EVENTS}")"
    echo "FIFO=$(basename "${SLOT_EVENTS_FIFO}")"
    echo "CHUNKLOG=$(slot_chunk_log 3)"
    echo "CHUNKEVENTS=$(slot_chunk_events 3)"
    echo "CHUNKFIFO=$(slot_chunk_fifo 3)"
    echo "LOGPREFIX=$(slot_chunk_log_prefix)"
  )
}

# --- the prep slot keeps every name it has today ------------------------------------------------
unset OVERTURE_RUN_SLOT
OUT="$(run_resolver)"
assert_contains "an absent slot is the prep slot" "${OUT}" "SLOT=prep"
assert_contains "the queue keeps its name" "${OUT}" "QUEUE=overture-prep-queue.json"
assert_contains "the results keep their name" "${OUT}" "RESULTS=overture-prep-results.json"
assert_contains "the progress file keeps its name" "${OUT}" "PROGRESS=overture-prep-progress.json"
assert_contains "the marker keeps its name" "${OUT}" "MARKER=prep-running"
assert_contains "the cancel sentinel keeps its name" "${OUT}" "CANCEL=prep-cancel"
assert_contains "the chunk dir keeps its name" "${OUT}" "CHUNKDIR=prep-chunks"
assert_contains "the pid file keeps its name" "${OUT}" "PIDFILE=prep-claude-pid"
assert_contains "the stall state keeps its name" "${OUT}" "STALL=prep-stall-state"
assert_contains "the log keeps its name" "${OUT}" "LOG=prep-run.log"
assert_contains "the events file keeps its name" "${OUT}" "EVENTS=prep-run-events.jsonl"
assert_contains "the events fifo keeps its name" "${OUT}" "FIFO=prep-run-events.fifo"
assert_contains "the chunk log keeps its name" "${OUT}" "CHUNKLOG=${SUPPORT_DIR}/prep-run.chunk-3.log"
assert_contains "the chunk events file keeps its name" "${OUT}" "CHUNKEVENTS=${SUPPORT_DIR}/prep-run-events.chunk-3.jsonl"
assert_contains "the chunk fifo keeps its name" "${OUT}" "CHUNKFIFO=${SUPPORT_DIR}/prep-events-chunk-3.fifo"

OUT="$(OVERTURE_RUN_SLOT="" run_resolver)"
assert_contains "an empty slot is the prep slot too" "${OUT}" "SLOT=prep"

OUT="$(OVERTURE_RUN_SLOT=prep run_resolver)"
assert_contains "an explicit prep slot is the prep slot" "${OUT}" "SLOT=prep"

# --- the check slot takes none of them ----------------------------------------------------------
OUT="$(OVERTURE_RUN_SLOT=check run_resolver)"
assert_contains "the check slot is its own" "${OUT}" "SLOT=check"
assert_contains "the check queue is its own" "${OUT}" "QUEUE=overture-check-queue.json"
assert_contains "the check results are its own" "${OUT}" "RESULTS=overture-check-results.json"
assert_contains "the check marker is its own" "${OUT}" "MARKER=check-running"
assert_contains "the check chunk dir is its own" "${OUT}" "CHUNKDIR=check-chunks"
assert_not_contains "the check slot takes no prep path" "${OUT}" "prep-"

# --- an unknown slot is refused, and says so where somebody can read it -------------------------
# The refusal has to be legible somewhere. Until open_run_log runs, this script's whole output goes to
# /dev/null (the app launches it as `sh -c '<script> >/dev/null 2>&1 &'`), so a refusal that only prints
# is a run that vanished without trace, which is what #485 and #1711 exist to stop.
rm -f "${SUPPORT_DIR}/runner-launch.log"
OUT="$(OVERTURE_RUN_SLOT=probe run_resolver 2>&1)"
assert_not_contains "an unknown slot never reaches the run" "${OUT}" "SLOT="
if [[ -f "${SUPPORT_DIR}/runner-launch.log" ]]; then
  TRACE="$(cat "${SUPPORT_DIR}/runner-launch.log")"
  assert_contains "the refusal names the value it was given" "${TRACE}" "probe"
  assert_contains "and names what it expected" "${TRACE}" "prep"
else
  fail "an unknown slot left no trace at all" "${SUPPORT_DIR}/runner-launch.log was never written"
fi

# Case is not guessed at: "Prep" is not a value anybody writes on purpose, so it is a disagreement rather
# than a spelling to be helpful about.
rm -f "${SUPPORT_DIR}/runner-launch.log"
OUT="$(OVERTURE_RUN_SLOT=Prep run_resolver 2>&1)"
assert_not_contains "a miscased slot is refused rather than corrected" "${OUT}" "SLOT="

# --- the entry wipe removes this slot's chunk files, on a path with a space in it ----------------
# The wipe is what stops a previous, larger run's chunk results being merged into this one as if they
# were its work. Driven here rather than asserted about, because the failure it is written against is
# invisible in the source: an unquoted glob on a path containing a space removes nothing and reports
# success. It must also leave the OTHER slot's files alone, which is the whole point of slotting it.
(
  SUPPORT="${SUPPORT_DIR}"
  . "${HERE}/run-slot.sh"
  OVERTURE_RUN_SLOT=prep resolve_run_slot
  touch "${SUPPORT_DIR}/prep-run.chunk-1.log" "${SUPPORT_DIR}/prep-run-events.chunk-1.jsonl"
  touch "${SUPPORT_DIR}/check-run.chunk-1.log" "${SUPPORT_DIR}/check-run-events.chunk-1.jsonl"
  mkdir -p "${SLOT_CHUNKDIR}" && touch "${SLOT_CHUNKDIR}/chunk-results-1.json"
  slot_wipe_chunk_files
)
assert_equals "the wipe removed this slot's chunk log" "absent" \
  "$([ -e "${SUPPORT_DIR}/prep-run.chunk-1.log" ] && echo present || echo absent)"
assert_equals "the wipe removed this slot's chunk events" "absent" \
  "$([ -e "${SUPPORT_DIR}/prep-run-events.chunk-1.jsonl" ] && echo present || echo absent)"
assert_equals "and left the other slot's chunk log alone" "present" \
  "$([ -e "${SUPPORT_DIR}/check-run.chunk-1.log" ] && echo present || echo absent)"
assert_equals "and left the other slot's chunk events alone" "present" \
  "$([ -e "${SUPPORT_DIR}/check-run-events.chunk-1.jsonl" ] && echo present || echo absent)"
assert_equals "the wipe took this slot's whole chunk directory" "absent" \
  "$([ -e "${SUPPORT_DIR}/prep-chunks" ] && echo present || echo absent)"
rm -f "${SUPPORT_DIR}/check-run.chunk-1.log" "${SUPPORT_DIR}/check-run-events.chunk-1.jsonl"

# --- and the runner does not name one behind the resolver's back -------------------------------
# The resolver is only worth having if it is the ONLY place these names are built. A literal left in the
# runner is a file the check will still share with the prep run after the two are meant to be separable,
# and it looks exactly like working code (L96: a hand-written list only checks what somebody remembered).
#
# The probe marker is the one deliberate exception and it is named here rather than pattern-matched, so
# removing it from the script does not quietly widen the guard: run identity moves onto the slot in #2760.
RUNNER="${HERE}/../prep-run.sh"
STRAYS="$(grep -n '\$SUPPORT/' "${RUNNER}" | grep -v 'reachability-probe-run.json' | grep -v '^[0-9]*:[[:space:]]*#' || true)"
assert_equals "no run file is named outside the resolver" "" "${STRAYS}"

# The control: that grep has to be able to FIND something, or a rename leaves it green over a script full
# of literals (L70). The one remaining literal is the positive control.
FOUND_PROBE="$(grep -c 'SUPPORT/reachability-probe-run.json' "${RUNNER}" || true)"
assert_equals "the scan still matches a real literal" "1" "${FOUND_PROBE}"

if [[ "${FAILURES:-0}" -ne 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all run-slot checks passed"
