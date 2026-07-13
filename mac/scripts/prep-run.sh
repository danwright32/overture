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
open_run_log "prep-run.log"

# See lib/resolve-node.sh (#636): puts a real node on PATH before claude (and its hooks) launch.
. "$(dirname "$0")/lib/resolve-node.sh"

QUEUE="$SUPPORT/overture-prep-queue.json"
RESULTS="$SUPPORT/overture-prep-results.json"
PROGRESS="$SUPPORT/overture-prep-progress.json"
RUNBOOK="$PROJECT_DIR/docs/prep-runbook.md"
MARKER="$SUPPORT/prep-running"

require_queue "$QUEUE" "prep"

# In-flight marker the app can watch (issue #44); removed on exit no matter what.
: > "$MARKER"

# #354: seed a fresh progress file every run (never trust a leftover one from a prior run) so
# the app's "N of M" display starts correct even if the agent below never updates it again.
JQ="$(command -v jq 2>/dev/null || echo /usr/bin/jq)"
TOTAL="$("$JQ" '.items | length' "$QUEUE" 2>/dev/null || echo 0)"
printf '{"version":1,"total":%s,"completed":0}\n' "$TOTAL" > "$PROGRESS"

# Heartbeat: keep the marker fresh while genuinely working so a long multi-prospect
# batch is never mistaken for a crashed run (#47). The app treats a marker untouched
# for a few minutes as dead; touching it every 60s keeps a real run alive without
# pinning the timeout to a guess at total run length.
( while :; do sleep 60; touch "$MARKER" 2>/dev/null || exit; done ) &
HEARTBEAT_PID=$!
trap 'kill "$HEARTBEAT_PID" 2>/dev/null; rm -f "$MARKER"' EXIT

PROMPT="You are the Overture Prep run. Follow $RUNBOOK exactly. FIRST, once per run, do the
'Learn from Dan's recent edits' step: read overture-voice-feedback.json if present and update
the anonymized auto-generated section of overture-voice-guidance.md (strip all org/venue/contact
specifics; never carry them into other drafts). Then read the work-list at $QUEUE, and for every
item find the contact (waterfall, strict verification) and draft the email in Dan's voice (invoke
the dan-wright-brand-voice skill; apply the voice guidance only as secondary nudges, the skill
wins). Copy each item's naturalKey verbatim. After finishing each item, overwrite $PROGRESS with
its completed count incremented by one, per the runbook's 'Update progress' step (total is already
seeded, never change it). Write the complete PrepResults JSON to $RESULTS and nothing else to that
file. Do the web research needed to find real, verifiable contacts.
"

resolve_claude

# Headless Claude Code run. Tools limited to what the run needs.
cd "$PROJECT_DIR"
# #868: the exit status is CAPTURED, never allowed to kill the script. Under `set -e` a claude that died
# (a crash, an API error, an out-of-memory kill) took the whole script down with it, right here, before
# anything below could react to what had been lost.
CLAUDE_STATUS=0
"$CLAUDE" -p "$PROMPT" \
  --model "${OVERTURE_MODEL_DRAFTING}" \
  --allowedTools "Read,Write,WebSearch,WebFetch,Bash,Skill" || CLAUDE_STATUS=$?

# #868: if the run wrote a results file that does not parse, move it aside. Left where it is, the app
# reads a FRESH file as a run that produced results, its decode fails, and it says nothing at all. Moved,
# the run reports as what it was, with the tail of this log. Prep is the worst place for that silence:
# this is the run that finds the contacts and writes the drafts.
quarantine_unreadable_results "$RESULTS"

# #804: stamp what actually wrote this, so a draft can be traced to the model behind it.
record_model "$RESULTS" "${OVERTURE_MODEL_DRAFTING}"

echo "prep run finished (claude exit ${CLAUDE_STATUS}) -> $RESULTS"
exit "$CLAUDE_STATUS"
