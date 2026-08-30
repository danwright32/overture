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
WORK="$(fixture_scratch_dir)"
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
    echo "VOICEFEEDBACK=${SHARED_VOICE_FEEDBACK}"
    echo "VOICEGUIDANCE=${SHARED_VOICE_GUIDANCE}"
    echo "RECENTOPENERS=${SHARED_RECENT_OPENERS}"
    echo "NAMED=${RUN_SLOT_WAS_NAMED}"
    echo "COVERS=$(basename "${SLOT_COVERS}")"
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
assert_contains "the covers file is named per slot" "${OUT}" "COVERS=prep-covers.json"
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

# --- and whether the slot was NAMED, which is a different fact from what it resolved to -----------
# #2980. Both of these resolve to prep, and prep-run.sh has to tell them apart: only a build older than
# #2763 names nothing, and only that build could launch a reachability CHECK in the prep slot with
# `reachability-probe-run.json` as the only thing saying so. A build that names `prep` is always the
# drafting run, so the marker must not be consulted for it. Asserted here at the resolver, and driven
# end to end through the runner itself in prep-run-chunking.test.sh.
assert_contains "a slot the caller named says so" "${OUT}" "NAMED=1"
assert_contains "an absent slot resolves to prep but is NOT named" \
  "$(unset OVERTURE_RUN_SLOT; run_resolver)" "NAMED=0"
assert_contains "and an empty value names nothing either" \
  "$(OVERTURE_RUN_SLOT="" run_resolver)" "NAMED=0"
assert_contains "the check slot is named too" "$(OVERTURE_RUN_SLOT=check run_resolver)" "NAMED=1"

# --- the check slot takes none of them ----------------------------------------------------------
OUT="$(OVERTURE_RUN_SLOT=check run_resolver)"
assert_contains "the check slot is its own" "${OUT}" "SLOT=check"
assert_contains "the check queue is its own" "${OUT}" "QUEUE=overture-check-queue.json"
assert_contains "the check results are its own" "${OUT}" "RESULTS=overture-check-results.json"
assert_contains "the check marker is its own" "${OUT}" "MARKER=check-running"
assert_contains "the check chunk dir is its own" "${OUT}" "CHUNKDIR=check-chunks"
assert_contains "the check covers file is its own" "${OUT}" "COVERS=check-covers.json"
assert_not_contains "the check slot takes no prep path" "${OUT}" "prep-"

# --- the voice artifacts are shared on purpose, and are the same file whichever slot asks ---------
# #2764. One drafting run at a time is what makes them safe to share, and a check never drafts. Slotting
# them would be the wrong fix and would silently give a check its own empty voice history.
PREP_VOICE="$(unset OVERTURE_RUN_SLOT; run_resolver | grep '^VOICEGUIDANCE=')"
CHECK_VOICE="$(OVERTURE_RUN_SLOT=check run_resolver | grep '^VOICEGUIDANCE=')"
assert_equals "the voice guidance is one file for both slots" "${PREP_VOICE}" "${CHECK_VOICE}"
assert_contains "and it sits in this run's own support dir, not a written-out one" "${PREP_VOICE}" "${SUPPORT_DIR}/overture-voice-guidance.md"

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

# --- the run proves it stayed in its own lane (#2764) --------------------------------------------
# The runbook no longer states a path and the prompt says its own paths win, but both are instructions to
# a model (L27). This is the deterministic half.
boundary_run() {
  (
    SUPPORT="${SUPPORT_DIR}"
    . "${HERE}/run-slot.sh"
    OVERTURE_RUN_SLOT="$1" resolve_run_slot
    slot_record_foreign_results
    # what the run "did" to the other slot's file
    eval "$2"
    slot_check_foreign_results
    echo "STATUS=$?"
  )
}

rm -f "${SUPPORT_DIR}"/overture-*-results.json "${SUPPORT_DIR}/run-boundary-violation.log"

# 1. Nothing to compare against is its OWN answer, never success (L98).
OUT="$(boundary_run prep ":")"
assert_contains "no other results file is reported as nothing compared" "${OUT}" "nothing was compared"
assert_not_contains "and is not dressed up as staying in its lane" "${OUT}" "stayed in its own lane"

# 2. The other slot's file exists and is untouched.
printf '{"results":[]}' > "${SUPPORT_DIR}/overture-check-results.json"
OUT="$(boundary_run prep ":")"
assert_contains "an untouched foreign results file passes" "${OUT}" "stayed in its own lane"
assert_contains "and says how many it compared" "${OUT}" "1 other slot"
assert_equals "with a zero status" "STATUS=0" "$(printf '%s' "${OUT}" | grep '^STATUS=')"

# 3. The run writes the OTHER slot's results file, which is the whole defect.
OUT="$(boundary_run prep "printf '{\"results\":[{\"naturalKey\":\"x\"}]}' > \"${SUPPORT_DIR}/overture-check-results.json\"")"
assert_contains "a changed foreign results file is a violation" "${OUT}" "BOUNDARY VIOLATION"
assert_contains "the violation names the slot that was written" "${OUT}" "check"
assert_equals "and it is a non-zero status" "STATUS=1" "$(printf '%s' "${OUT}" | grep '^STATUS=')"
assert_contains "the violation is written somewhere durable, not only to a log that scrolls" \
  "$(cat "${SUPPORT_DIR}/run-boundary-violation.log" 2>/dev/null || echo MISSING)" "BOUNDARY VIOLATION"

# 4. A foreign file APPEARING mid-run counts too: absent to present is a change.
rm -f "${SUPPORT_DIR}"/overture-*-results.json "${SUPPORT_DIR}/run-boundary-violation.log"
OUT="$(boundary_run prep "printf '{}' > \"${SUPPORT_DIR}/overture-check-results.json\"")"
assert_contains "a foreign results file that appears mid-run is a violation" "${OUT}" "BOUNDARY VIOLATION"

# 5. Content, not size and time: same length, different bytes.
rm -f "${SUPPORT_DIR}"/overture-*-results.json "${SUPPORT_DIR}/run-boundary-violation.log"
printf 'AAAA' > "${SUPPORT_DIR}/overture-check-results.json"
OUT="$(boundary_run prep "printf 'BBBB' > \"${SUPPORT_DIR}/overture-check-results.json\"")"
assert_contains "a same-length rewrite is still a violation" "${OUT}" "BOUNDARY VIOLATION"

# 6. This run's OWN results file is not foreign to it: writing it is the job.
rm -f "${SUPPORT_DIR}"/overture-*-results.json "${SUPPORT_DIR}/run-boundary-violation.log"
# --- #3016: a change while the two runs SHARED the machine is undecidable, not a violation ---------
# Once #3015 lets both run at once, the other slot's results file changing during this run is the
# ORDINARY case: it is that run writing its own answers. From here that is indistinguishable from this
# run having written them, so the guard must say it cannot tell rather than accuse (L11, L93). A guard
# that fires on the ordinary case gets switched off within a day.
rm -f "${SUPPORT_DIR}"/overture-*-results.json "${SUPPORT_DIR}/run-boundary-violation.log"
printf 'before' > "${SUPPORT_DIR}/overture-check-results.json"
OUT="$(
  SUPPORT="${SUPPORT_DIR}"
  . "${HERE}/run-slot.sh"
  . "${HERE}/run-contention.sh"
  OVERTURE_RUN_SLOT=prep resolve_run_slot
  # A check was alive at some point during this run, which is what contention_observe latches.
  printf 'check\n' > "${SLOT_CONTENDED}"
  slot_record_foreign_results
  printf 'after' > "${SUPPORT_DIR}/overture-check-results.json"
  slot_check_foreign_results
)"
assert_not_contains "a change under contention is not called a violation" "${OUT}" "BOUNDARY VIOLATION"
assert_contains "and it says which run it shared the machine with" "${OUT}" "check"
assert_contains "and refuses to call the run clean either" "${OUT}" "neither blamed nor cleared"
if [[ -f "${SUPPORT_DIR}/run-boundary-violation.log" ]]; then
  fail "an undecidable change was written to the violations log" "the log must hold accusations only"
else
  pass "nothing was written to the violations log"
fi

# THE POSITIVE CONTROL, same change, same files, with NO contention recorded: still a violation. Without
# this the assertions above pass on a guard that has simply stopped working (L159).
rm -f "${SUPPORT_DIR}/run-boundary-violation.log"
printf 'before' > "${SUPPORT_DIR}/overture-check-results.json"
OUT="$(
  SUPPORT="${SUPPORT_DIR}"
  . "${HERE}/run-slot.sh"
  . "${HERE}/run-contention.sh"
  OVERTURE_RUN_SLOT=prep resolve_run_slot
  : > "${SLOT_CONTENDED}"
  slot_record_foreign_results
  printf 'after' > "${SUPPORT_DIR}/overture-check-results.json"
  slot_check_foreign_results
)"
assert_contains "the same change with nothing else running IS still a violation" "${OUT}" "BOUNDARY VIOLATION"
assert_contains "and says why nothing else can account for it" "${OUT}" "No other run slot was alive"
rm -f "${SUPPORT_DIR}"/overture-*-results.json "${SUPPORT_DIR}/run-boundary-violation.log"

OUT="$(boundary_run prep "printf '{}' > \"${SUPPORT_DIR}/overture-prep-results.json\"")"
assert_not_contains "writing its own results is never a violation" "${OUT}" "BOUNDARY VIOLATION"
rm -f "${SUPPORT_DIR}"/overture-*-results.json "${SUPPORT_DIR}/run-boundary-violation.log"

# And it is WIRED, which is a separate claim from working (L3). It has to be in the EXIT trap: the script
# ends in `exit "$CLAUDE_STATUS"`, so a call placed after that is dead code, which is where the first
# version of this went.
TRAP_LINE="$(grep -n "^trap " "${HERE}/../prep-run.sh")"
assert_contains "the boundary check runs on every exit path" "${TRAP_LINE}" "slot_check_foreign_results"

# --- #3010: the covers file is released on exit, and AFTER the marker --------------------------
# The order is the guard, not decoration. Overture reads a slot's coverage only when that slot's marker
# says it is LIVE, so marker-then-covers leaves an inert state if the run dies between the two removals
# (the read answers "no live run"), while covers-then-marker leaves marker-live-plus-covers-absent, which
# is the REFUSAL state and would block the next launch for a run that has already ended.
assert_contains "the covers file is released on every exit path" "${TRAP_LINE}" "SLOT_COVERS"
MARKER_AT="$(awk '{print index($0, "rm -f \"$MARKER\"")}' <<<"${TRAP_LINE}")"
COVERS_AT="$(awk '{print index($0, "rm -f \"$SLOT_COVERS\"")}' <<<"${TRAP_LINE}")"
if [[ "${MARKER_AT}" -gt 0 && "${COVERS_AT}" -gt 0 && "${MARKER_AT}" -lt "${COVERS_AT}" ]]; then
  pass "the marker is removed BEFORE the covers file"
else
  fail "the marker is removed BEFORE the covers file" \
    "marker at ${MARKER_AT}, covers at ${COVERS_AT}: covers-first leaves a live-looking slot with no coverage"
fi
assert_contains "and the fingerprint is taken before the run" \
  "$(grep -c 'slot_record_foreign_results' "${HERE}/../prep-run.sh")" "1"

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
