#!/bin/sh
# Reply-classify runner: launched DETACHED by the Overture app when replies need an intent read.
# Drives a Claude Code run on Dan's Max plan that reads the work-list, classifies each reply's
# intent (see docs/reply-classify-runbook.md), and writes the results file the app ingests. Runs
# headless; the app does not supervise it.
#
# Configure the app to point at this script: set the UserDefaults key 'replyClassifyRunnerScriptPath'
# to this file's path, and chmod +x it.

set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)/.."   # the Overture repo root

# See lib/runner-setup.sh (#552): shared support-dir resolution, log redirection, and early-guard
# structure with prep-run.sh.
. "$(dirname "$0")/lib/runner-setup.sh"
open_run_log "reply-classify-run.log"

# See lib/resolve-node.sh (#636): puts a real node on PATH before claude (and its hooks) launch.
. "$(dirname "$0")/lib/resolve-node.sh"

QUEUE="$SUPPORT/overture-reply-classify-queue.json"
RESULTS="$SUPPORT/overture-reply-classify-results.json"
RUNBOOK="$PROJECT_DIR/docs/reply-classify-runbook.md"
VOICE="$SUPPORT/overture-voice-guidance.md"
MARKER="$SUPPORT/reply-classify-running"

require_queue "$QUEUE" "reply-classify"

# In-flight marker the app watches; removed on exit no matter what.
: > "$MARKER"

# Heartbeat: keep the marker fresh while working so a longer batch isn't mistaken for a crash.
( while :; do sleep 60; touch "$MARKER" 2>/dev/null || exit; done ) &
HEARTBEAT_PID=$!
trap 'kill "$HEARTBEAT_PID" 2>/dev/null; rm -f "$MARKER"' EXIT

PROMPT="You are the Overture reply-classify + reply-drafter run (v3). Follow $RUNBOOK exactly. Read the
work-list at $QUEUE. For EVERY item: (1) classify the reply's intent as exactly one of interested,
wants_to_book, has_question, or declined; (2) DRAFT a short reply in Dan's voice that responds to what
the contact actually wrote, emitting draftSubject and draftBody. NEVER ask the contact for the date,
venue, or location (#438): each item carries venue and performanceDate (the show Overture already knows) —
REFERENCE them, never request them (e.g. 'your March 10 concert at Carnegie Hall', never 'let me know the
date'). Read Dan's distilled voice guidance at
$VOICE and apply ONLY those distilled tendencies — NEVER quote or paraphrase raw past email pairs
(the #119/#249 leak guard). Copy each item's naturalKey AND recipientId verbatim so each result attaches
to the right contact. Write the complete v3 ReplyClassifyResults JSON (version 3; each result =
{naturalKey, recipientId, intent, draftSubject, draftBody}) to $RESULTS and nothing else to that file.
If $VOICE is absent, draft from the runbook's voice rules alone."

resolve_claude

# Headless Claude Code run; reading the reply text and writing the results is all it needs.
cd "$PROJECT_DIR"
"$CLAUDE" -p "$PROMPT" \
  --allowedTools "Read,Write"

echo "reply-classify run finished -> $RESULTS"
