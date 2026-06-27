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
SUPPORT="$HOME/Library/Application Support/Overture"
QUEUE="$SUPPORT/overture-prep-queue.json"
RESULTS="$SUPPORT/overture-prep-results.json"
RUNBOOK="$PROJECT_DIR/docs/prep-runbook.md"
MARKER="$SUPPORT/prep-running"

# Refuse to start if no work-list is present.
[ -f "$QUEUE" ] || { echo "no prep queue at $QUEUE" >&2; exit 1; }

# In-flight marker the app can watch (issue #44); removed on exit no matter what.
: > "$MARKER"

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
wins). Copy each item's naturalKey verbatim. Write the complete PrepResults JSON to $RESULTS and
nothing else to that file. Do the web research needed to find real, verifiable contacts."

# Resolve the claude binary: the app launches us with a minimal PATH, so look in the
# usual install spots rather than relying on PATH.
CLAUDE=""
for c in "$HOME/.local/bin/claude" "/usr/local/bin/claude" "/opt/homebrew/bin/claude" "$(command -v claude 2>/dev/null || true)"; do
  if [ -n "$c" ] && [ -x "$c" ]; then CLAUDE="$c"; break; fi
done
[ -n "$CLAUDE" ] || { echo "claude CLI not found" >&2; exit 1; }

# Headless Claude Code run. Tools limited to what the run needs.
cd "$PROJECT_DIR"
"$CLAUDE" -p "$PROMPT" \
  --allowedTools "Read,Write,WebSearch,WebFetch,Bash,Skill" \
  >> "$SUPPORT/prep-run.log" 2>&1

echo "prep run finished -> $RESULTS"
