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
}

# The per-chunk family. Functions rather than variables because the index is not known until the queue is
# split, and a glob built from the slot is what the entry wipe needs.
slot_chunk_log() { echo "${SUPPORT}/${RUN_SLOT}-run.chunk-$1.log"; }
slot_chunk_events() { echo "${SUPPORT}/${RUN_SLOT}-run-events.chunk-$1.jsonl"; }
slot_chunk_fifo() { echo "${SUPPORT}/${RUN_SLOT}-events-chunk-$1.fifo"; }
slot_chunk_log_glob() { echo "${SUPPORT}/${RUN_SLOT}-run.chunk-*.log"; }
slot_chunk_events_glob() { echo "${SUPPORT}/${RUN_SLOT}-run-events.chunk-*.jsonl"; }
