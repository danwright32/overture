# Sourced (not executed) by prep-run.sh, which is /bin/sh, so everything here stays POSIX.
# #2763 (phase 1 of #2620): which set of files this run owns.
#
# A reachability check and a Prep run were given ONE set of fixed filenames, every one of them written
# into this script by hand, so the single-runner lock is preventing a FILENAME COLLISION rather than a
# conflict in the work. Everything below is the shell half of `RunSlot` (mac/Overture/Domain/RunSlot.swift),
# which owns the same names on the app side.
#
# Sourced with SUPPORT already set (see runner-setup.sh), and BEFORE open_run_log, because the log's own
# name comes from here.
#
# The slot arrives in the ENVIRONMENT rather than as an argument, and an ABSENT value means prep. That is
# compatibility, not laziness: this script does not ship inside the app bundle, it is resolved from a
# UserDefaults path into the git checkout, and mac/scripts/update-overture.sh fast-forwards the checkout
# BEFORE the 90 second rebuild. So a new script meets an old app that names no slot, for a couple of
# minutes on every update and permanently for anyone who only pulls. An argument would simply be missing
# there and Prep would die; the environment carries the default instead. An UNKNOWN value is refused,
# because that is a different fact: the two halves disagree about what a slot is.

# Where a refusal goes when there is no slot to name a log after. The app launches this script as
# `sh -c '<script> >/dev/null 2>&1 &'`, so until open_run_log runs there is no trace of anything, which is
# the traceless early death #485 and #1711 exist to prevent. This file is slot-independent on purpose.
RUNNER_LAUNCH_LOG_NAME="runner-launch.log"

resolve_run_slot() {
  RUN_SLOT="${OVERTURE_RUN_SLOT:-prep}"
  [ -n "${RUN_SLOT}" ] || RUN_SLOT="prep"

  case "${RUN_SLOT}" in
    prep|check) ;;
    *)
      mkdir -p "${SUPPORT}" 2>/dev/null || true
      {
        echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') run-slot: refusing to start."
        echo "  OVERTURE_RUN_SLOT was '${RUN_SLOT}', which this script does not recognise."
        echo "  It knows 'prep' and 'check'. An unset value means prep."
        echo "  Nothing was written and no run was started: a run that cannot tell which files are its"
        echo "  own would write another run's."
      } >> "${SUPPORT}/${RUNNER_LAUNCH_LOG_NAME}"
      exit 1
      ;;
  esac

  # Every name is built from the slot, so `prep` reproduces the strings already written into
  # docs/contracts.md, docs/prep-runbook.md and Dan's Application Support folder.
  SLOT_QUEUE="${SUPPORT}/overture-${RUN_SLOT}-queue.json"
  SLOT_RESULTS="${SUPPORT}/overture-${RUN_SLOT}-results.json"
  SLOT_PROGRESS="${SUPPORT}/overture-${RUN_SLOT}-progress.json"
  SLOT_MARKER="${SUPPORT}/${RUN_SLOT}-running"
  SLOT_CANCEL="${SUPPORT}/${RUN_SLOT}-cancel"
  SLOT_CHUNKDIR="${SUPPORT}/${RUN_SLOT}-chunks"
  SLOT_CLAUDE_PID="${SUPPORT}/${RUN_SLOT}-claude-pid"
  SLOT_STALL_STATE="${SUPPORT}/${RUN_SLOT}-stall-state"
  SLOT_EVENTS="${SUPPORT}/${RUN_SLOT}-run-events.jsonl"
  SLOT_EVENTS_FIFO="${SUPPORT}/${RUN_SLOT}-run-events.fifo"
  # open_run_log takes a NAME rather than a path, so this one is not absolute.
  SLOT_LOG_NAME="${RUN_SLOT}-run.log"

  # #2764: the voice artifacts, which are deliberately NOT slot-scoped and must not become so. One
  # drafting run at a time is exactly what makes them safe to share, and a check never touches them
  # (it does not draft). They are named here anyway, with everything else, so that no runner has to
  # spell out a handoff path itself and the Debug folder is honoured for free: the runbook used to
  # state them as ~/Library/Application Support/Overture/..., which is the Release folder, so a Debug
  # run following it read and wrote Dan's live voice files.
  SHARED_VOICE_FEEDBACK="${SUPPORT}/overture-voice-feedback.json"
  SHARED_RECENT_OPENERS="${SUPPORT}/overture-recent-openers.json"
  SHARED_VOICE_GUIDANCE="${SUPPORT}/overture-voice-guidance.md"
}

# The per-chunk family. Functions rather than variables because the index is not known until the queue is
# split.
slot_chunk_log() { echo "${SUPPORT}/${RUN_SLOT}-run.chunk-$1.log"; }
slot_chunk_events() { echo "${SUPPORT}/${RUN_SLOT}-run-events.chunk-$1.jsonl"; }
slot_chunk_fifo() { echo "${SUPPORT}/${RUN_SLOT}-events-chunk-$1.fifo"; }

# The entry wipe needs a GLOB, and a glob cannot come back from a function: the live support directory is
# "~/Library/Application Support/Overture", so an unquoted `$(...)` expansion word-splits on that space
# and the wipe removes nothing at all while looking exactly like it worked. These are prefixes instead,
# quoted at the call site with the `*` outside the quotes, which is how the literal wipe was written
# before the slot existed.
slot_chunk_log_prefix() { echo "${SUPPORT}/${RUN_SLOT}-run.chunk-"; }
slot_chunk_events_prefix() { echo "${SUPPORT}/${RUN_SLOT}-run-events.chunk-"; }

# The entry wipe itself, so the runner and its fixture drive ONE implementation. Written out at the call
# site instead, the fixture would only ever prove that its own copy of these two lines works (L52).
#
# What it protects: a leftover chunk-results file from a previous, larger run must never be merged into
# this one as if it were this run's work. Slot-scoped, so a starting check cannot take a live prep's
# chunk logs with it.
slot_wipe_chunk_files() {
  rm -rf "${SLOT_CHUNKDIR}" 2>/dev/null || true
  rm -f "$(slot_chunk_log_prefix)"*.log "$(slot_chunk_events_prefix)"*.jsonl 2>/dev/null || true
}

# #2764: did this run stay in its own lane?
#
# The runbook no longer states a path and the prompt says its own paths win, but both of those are
# instructions to a model, and a rule that lives only in a prompt is a hope (L27). This is the
# deterministic half: fingerprint every OTHER slot's results file before the run, and check it again
# after. A change means something followed a path it was not given and wrote another run's answers.
#
# Content, not size-and-time: a stand-in that happens to match keeps the stale reading (L40). `cksum` is
# POSIX and reads the bytes.
slot_results_fingerprint() {
  if [ -f "$1" ]; then cksum < "$1"; else echo "absent"; fi
}

# The slots that are not this one. Listed here rather than at the call site so adding a third slot
# cannot leave a run unchecked against it.
slot_others() {
  for candidate in prep check; do
    [ "${candidate}" = "${RUN_SLOT}" ] || echo "${candidate}"
  done
}

slot_record_foreign_results() {
  FOREIGN_RESULTS_BEFORE=""
  for other in $(slot_others); do
    fp="$(slot_results_fingerprint "${SUPPORT}/overture-${other}-results.json")"
    FOREIGN_RESULTS_BEFORE="${FOREIGN_RESULTS_BEFORE}${other}|${fp}
"
  done
}

# Reports one of three outcomes, never two. "Nothing to compare" is its own answer and is NOT success:
# finding no subject is exactly what a check that never ran looks like (L98).
slot_check_foreign_results() {
  checked=0
  violated=0
  for other in $(slot_others); do
    before="$(printf '%s' "${FOREIGN_RESULTS_BEFORE}" | grep "^${other}|" | cut -d'|' -f2-)"
    after="$(slot_results_fingerprint "${SUPPORT}/overture-${other}-results.json")"
    if [ "${before}" = "absent" ] && [ "${after}" = "absent" ]; then
      continue
    fi
    checked=$((checked + 1))
    if [ "${before}" != "${after}" ]; then
      violated=$((violated + 1))
      {
        echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') run-slot: BOUNDARY VIOLATION."
        echo "  This run is the '${RUN_SLOT}' slot, and the '${other}' slot's results file CHANGED while"
        echo "  it was running: ${SUPPORT}/overture-${other}-results.json"
        echo "  before: ${before}"
        echo "  after:  ${after}"
        echo "  Something followed a path it was not given. Another run's answers may have been"
        echo "  overwritten, and that run cannot tell."
      } | tee -a "${SUPPORT}/run-boundary-violation.log"
    fi
  done
  if [ "${violated}" -gt 0 ]; then
    echo "prep: ${violated} boundary violation(s). See ${SUPPORT}/run-boundary-violation.log"
    return 1
  fi
  if [ "${checked}" -eq 0 ]; then
    echo "prep: no other slot had a results file to check against (nothing was compared)."
    return 0
  fi
  echo "prep: stayed in its own lane (${checked} other slot results file(s) unchanged)."
  return 0
}
