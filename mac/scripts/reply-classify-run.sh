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
# #804: which model this run uses, and the helper that records it. One place, so a model choice
# cannot be right in two runners and wrong in the third.
. "$(dirname "$0")/lib/models.sh"
# #868: a results file that does not parse is not results. Left in place it reads as a fresh, successful
# run and the app fails to decode it in total silence.
. "$(dirname "$0")/lib/results-guard.sh"
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
venue, or location (#438): each item carries venue and performanceDate (the show Overture already knows).
REFERENCE them, never request them (e.g. 'your March 10 concert at Carnegie Hall', never 'let me know the
date').

#872: Dan's VOICE is defined in exactly one place. Invoke the dan-wright-brand-voice skill and draft from
it, the same way the Prep run does. This reply goes to a real person who wrote back to him, so it is his
voice or it is nobody's. The skill is AUTHORITATIVE and wins over everything else here. Its hard rules
are absolute: no em dashes, contractions throughout, and NO fabrication (never invent a fact about the
show, the contact, or Dan's availability). Then read his distilled voice guidance at
$VOICE and apply those tendencies only as secondary nudges, never over the skill, and NEVER quote or
paraphrase raw past email pairs (the #119/#249 leak guard). Copy each item's naturalKey AND recipientId
verbatim so each result attaches to the right contact. Write the complete v3 ReplyClassifyResults JSON
(version 3; each result = {naturalKey, recipientId, intent, draftSubject, draftBody}) to $RESULTS and
nothing else to that file. If $VOICE is absent, draft from the skill alone: it is the authority, and the
guidance file only ever nudges.
"

resolve_claude

# Headless Claude Code run. Read (the work-list and the voice guidance), Write (the results), and #872:
# Skill, so this run can invoke dan-wright-brand-voice. Without that tool the prompt's instruction to use
# the skill is one the model cannot obey, and it would silently fall back to inventing his voice, which
# is exactly what it was doing before.
cd "$PROJECT_DIR"
# #868: the exit status is CAPTURED, never allowed to kill the script. Under `set -e` a claude that died
# took the whole script down with it, right here, before anything below could react.
CLAUDE_STATUS=0
"$CLAUDE" -p "$PROMPT" \
  --model "${OVERTURE_MODEL_REPLY_CLASSIFY}" \
  --allowedTools "Read,Write,Skill" || CLAUDE_STATUS=$?

# #868: a results file that does not parse is moved aside, so the app reports an empty run instead of
# failing to decode it in silence. Nothing is invented in its place: a fabricated intent would drive a
# conversation state off a decision no model ever made.
quarantine_unreadable_results "$RESULTS"

# #804: stamp what actually wrote this, so a draft can be traced to the model behind it.
record_model "$RESULTS" "${OVERTURE_MODEL_REPLY_CLASSIFY}"

echo "reply-classify run finished (claude exit ${CLAUDE_STATUS}) -> $RESULTS"
exit "$CLAUDE_STATUS"
