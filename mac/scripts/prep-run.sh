#!/bin/sh
# Prep runner: launched DETACHED by the Overture app's "Prep kept" button. Drives a
# Claude Code run on Dan's Max plan that reads the work-list, finds a contact and
# drafts an email per prospect (see docs/prep-runbook.md), and writes the results
# file the app ingests. Runs headless; the app does not supervise it.
#
# Configure the app to point at this script: set the UserDefaults key
# 'prepRunnerScriptURL' to this file's path (a file:// URL), and chmod +x it.

set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)/.."   # the Overture repo root

# See lib/runner-setup.sh (#552): shared support-dir resolution, log redirection, and early-guard
# structure with reply-classify-run.sh.
. "$(dirname "$0")/lib/runner-setup.sh"
# #804: which model this run uses, and the helper that records it. One place, so a model choice
# cannot be right in two runners and wrong in the third.
. "$(dirname "$0")/lib/models.sh"
# #868: a results file that does not parse is not results. Left in place it reads as a fresh, successful
# run and the app fails to decode it in total silence.
. "$(dirname "$0")/lib/results-guard.sh"
# #1023: derives the "N of M" progress count from the results file itself (the SAME helper scout uses,
# #1015), so the toolbar can never sit stuck at 0 just because the model forgot to self-report a count,
# which is exactly what silently failed for scout on 2026-07-16.
. "$(dirname "$0")/lib/progress-watcher.sh"
# #1038: the cooperative cancel check (the SAME predicates scout uses, #1037). Overture writes a
# cancel-request file; the heartbeat below checks for it each tick and stops the run cleanly. A detached
# run has no trackable PID (DetachedRunner backgrounds the whole script via `sh -c '... &'`), so a hard
# kill of the script is off the table; the stop is cooperative, and it lands at a poll boundary so it can
# never interrupt a draft mid-write and corrupt the shared results file.
. "$(dirname "$0")/lib/scout-cancel.sh"
open_run_log "prep-run.log"

# See lib/resolve-node.sh (#636): puts a real node on PATH before claude (and its hooks) launch.
. "$(dirname "$0")/lib/resolve-node.sh"

QUEUE="$SUPPORT/overture-prep-queue.json"
RESULTS="$SUPPORT/overture-prep-results.json"
PROGRESS="$SUPPORT/overture-prep-progress.json"
RUNBOOK="$PROJECT_DIR/docs/prep-runbook.md"
MARKER="$SUPPORT/prep-running"

# #1038: the cooperative-cancel sentinel Overture writes to stop this run, and the file the heartbeat
# reads to know which claude process to stop when it sees the sentinel. The heartbeat is forked before
# claude launches, so it cannot see CLAUDE_PID directly; claude writes its PID here for it (mirrors
# scout-extract-run.sh's CHUNK_PIDS_FILE).
CANCEL="$SUPPORT/prep-cancel"
CLAUDE_PID_FILE="$SUPPORT/prep-claude-pid"
# A sentinel or PID left over from a previous cancelled run must never stop THIS one before it starts.
# Overture clears the sentinel too, before launching; this is defence in depth (assume-it-runs-twice).
clear_cancel "$CANCEL"
rm -f "$CLAUDE_PID_FILE" 2>/dev/null || true

require_queue "$QUEUE" "prep"

# In-flight marker the app can watch (issue #44); removed on exit no matter what.
: > "$MARKER"

# #354: seed a fresh progress file every run (never trust a leftover one from a prior run) so
# the app's "N of M" display starts correct even before any result has landed.
JQ="$(command -v jq 2>/dev/null || echo /usr/bin/jq)"
TOTAL="$("$JQ" '.items | length' "$QUEUE" 2>/dev/null || echo 0)"
printf '{"version":1,"total":%s,"completed":0}\n' "$TOTAL" > "$PROGRESS"

# Heartbeat: keep the marker fresh while genuinely working so a long multi-prospect batch is never
# mistaken for a crashed run (#47). The app treats a marker untouched for a few minutes as dead.
#
# #1023: the marker tick also DERIVES progress from $RESULTS (the SAME update_progress_from_results scout
# uses), so the "N of M" count is a fact the script establishes by counting what has actually landed in
# the results file, never a number the model has to remember to self-report (which it forgot once, leaving
# scout's counter stuck at 0 through a live run on 2026-07-16).
#
# #1038: the loop also honours a cancel. The cancel is read on a SHORT poll (PREP_CANCEL_POLL_SECONDS,
# default 3), DECOUPLED from the 60s marker/derive work by marker_due, so a Cancel Dan clicks stops the
# run (and its token spend) within a few seconds instead of up to a minute. When the sentinel is present
# the heartbeat stops the claude process it recorded and exits; the main script's `wait` then returns and
# it exits through normal cleanup. The kill lands at a poll boundary and never interrupts a results write
# (the derive runs only on the marker branch), so no draft is corrupted mid-write.
CANCEL_POLL="${PREP_CANCEL_POLL_SECONDS:-3}"
MARKER_INTERVAL=60
( since_marker=0
  while :; do
    sleep "$CANCEL_POLL"
    if cancel_requested "$CANCEL"; then
      # shellcheck disable=SC2046
      [ -s "$CLAUDE_PID_FILE" ] && kill $(cat "$CLAUDE_PID_FILE" 2>/dev/null) 2>/dev/null
      exit
    fi
    since_marker=$((since_marker + CANCEL_POLL))
    if marker_due "$since_marker" "$MARKER_INTERVAL"; then
      since_marker=0
      touch "$MARKER" 2>/dev/null || exit
      update_progress_from_results "$QUEUE" "$RESULTS" "$PROGRESS"
    fi
  done ) &
HEARTBEAT_PID=$!
# CLAUDE_PID is filled in below once claude launches; killing it on exit stops a killed script (Dan
# quits the app, a crash) from leaving an orphaned claude running against the queue.
CLAUDE_PID=""
# #1038: clear the cancel sentinel and the pid file on exit too, so a stopped run never leaves a sentinel
# that would instantly kill the next run.
trap 'kill "$HEARTBEAT_PID" 2>/dev/null; [ -n "$CLAUDE_PID" ] && kill "$CLAUDE_PID" 2>/dev/null; rm -f "$MARKER"; clear_cancel "$CANCEL"; rm -f "$CLAUDE_PID_FILE"' EXIT

# #1013: the last run's results are spent, and leaving them here lets them masquerade as this run's.
# scout-extract-run.sh learned this in #1011 (a run that wrote nothing inherited the previous run's
# file wholesale, generatedAt and all); prep is the worse place for the same bug, since a stale result
# carries real contacts and drafted email text.
discard_previous_results "$RESULTS"

PROMPT="You are the Overture Prep run. Follow $RUNBOOK exactly. FIRST, once per run, do the
'Learn from Dan's recent edits' step: read overture-voice-feedback.json if present and update
the anonymized auto-generated section of overture-voice-guidance.md (strip all org/venue/contact
specifics; never carry them into other drafts). Then read the work-list at $QUEUE, and for every
item find the contact (waterfall, strict verification) and draft the email in Dan's voice (invoke
the dan-wright-brand-voice skill; apply the voice guidance only as secondary nudges, the skill
wins). Copy each item's naturalKey verbatim. Immediately after finishing EACH item, rewrite $RESULTS
with the complete PrepResults JSON covering EVERY item you have finished so far, not just this one.
Do this after every single item, not only at the end: the app derives its live 'N of M' progress from
this file's own entry count, so the last time you do this simply IS the end, and you must never wait
until the whole work-list is done to write anything. Write the complete PrepResults JSON to $RESULTS
and nothing else to that file. This run is DETACHED: nobody can answer you, so never stop to ask,
decide and record the decision in the result. Do the web research needed to find real, verifiable contacts.
"

resolve_claude

# Headless Claude Code run. Tools limited to what the run needs.
cd "$PROJECT_DIR"
# #868: the exit status is CAPTURED, never allowed to kill the script. Under `set -e` a claude that died
# (a crash, an API error, an out-of-memory kill) took the whole script down with it, right here, before
# anything below could react to what had been lost.
#
# #1038: claude runs in the BACKGROUND now, with its PID recorded, so the heartbeat above can stop exactly
# this process on a cancel (the heartbeat was forked before this, so it cannot see CLAUDE_PID directly;
# the pid file hands it over, mirroring scout's chunk PIDs). `wait` blocks until claude finishes or the
# cancel kills it; either way its status is captured. Written as `|| ...` so a non-zero status (including
# the signal from a cancel) cannot trip `set -e` and take the whole script down on the failure path.
CLAUDE_STATUS=0
"$CLAUDE" -p "$PROMPT" \
  --model "${OVERTURE_MODEL_DRAFTING}" \
  --allowedTools "Read,Write,WebSearch,WebFetch,Bash,Skill" &
CLAUDE_PID=$!
printf '%s' "$CLAUDE_PID" > "$CLAUDE_PID_FILE"
wait "$CLAUDE_PID" || CLAUDE_STATUS=$?
CLAUDE_PID=""   # reaped; nothing left for the trap to kill

# #1023: one last derive now that claude has exited, so the count reflects whatever landed between the
# previous heartbeat tick and the process actually finishing, rather than sitting stale.
update_progress_from_results "$QUEUE" "$RESULTS" "$PROGRESS"

# #868: if the run wrote a results file that does not parse, move it aside. Left where it is, the app
# reads a FRESH file as a run that produced results, its decode fails, and it says nothing at all. Moved,
# the run reports as what it was, with the tail of this log. Prep is the worst place for that silence:
# this is the run that finds the contacts and writes the drafts.
quarantine_unreadable_results "$RESULTS"

# #804: stamp what actually wrote this, so a draft can be traced to the model behind it.
record_model "$RESULTS" "${OVERTURE_MODEL_DRAFTING}"

echo "prep run finished (claude exit ${CLAUDE_STATUS}) -> $RESULTS"
exit "$CLAUDE_STATUS"
