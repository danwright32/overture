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
SUPPORT="$HOME/Library/Application Support/Overture"
QUEUE="$SUPPORT/overture-reply-classify-queue.json"
RESULTS="$SUPPORT/overture-reply-classify-results.json"
RUNBOOK="$PROJECT_DIR/docs/reply-classify-runbook.md"
MARKER="$SUPPORT/reply-classify-running"

# Refuse to start if no work-list is present.
[ -f "$QUEUE" ] || { echo "no reply-classify queue at $QUEUE" >&2; exit 1; }

# In-flight marker the app watches; removed on exit no matter what.
: > "$MARKER"

# Heartbeat: keep the marker fresh while working so a longer batch isn't mistaken for a crash.
( while :; do sleep 60; touch "$MARKER" 2>/dev/null || exit; done ) &
HEARTBEAT_PID=$!
trap 'kill "$HEARTBEAT_PID" 2>/dev/null; rm -f "$MARKER"' EXIT

PROMPT="You are the Overture reply-classify run. Follow $RUNBOOK exactly. Read the work-list at
$QUEUE, and for every item read the reply text and classify its intent as exactly one of
interested, wants_to_book, has_question, or declined. Copy each item's naturalKey verbatim. Write
the complete ReplyClassifyResults JSON to $RESULTS and nothing else to that file."

# Resolve the claude binary: the app launches us with a minimal PATH.
CLAUDE=""
for c in "$HOME/.local/bin/claude" "/usr/local/bin/claude" "/opt/homebrew/bin/claude" "$(command -v claude 2>/dev/null || true)"; do
  if [ -n "$c" ] && [ -x "$c" ]; then CLAUDE="$c"; break; fi
done
[ -n "$CLAUDE" ] || { echo "claude CLI not found" >&2; exit 1; }

# Headless Claude Code run; reading the reply text and writing the results is all it needs.
cd "$PROJECT_DIR"
"$CLAUDE" -p "$PROMPT" \
  --allowedTools "Read,Write" \
  >> "$SUPPORT/reply-classify-run.log" 2>&1

echo "reply-classify run finished -> $RESULTS"
