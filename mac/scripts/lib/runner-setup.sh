# Sourced (not executed) by the headless runner scripts (prep-run.sh, reply-classify-run.sh).
# Both scripts drive the same class of setup before invoking claude: resolve the app's
# handoff dir, open the run log before any guard below can exit, refuse to start with no
# work-list, and resolve the claude binary. That duplication has needed the same fix twice,
# once per script, across three rounds (#317/#437, #439, #485): pulled here so the next fix
# in this class lands once. See #552.

# Declares that this run is DETACHED: launched by the app, headless, with nobody reading its output
# and nothing able to answer it. Dan's global Stop hooks in ~/.claude/hooks (the session reflection,
# the issue review, the memory checkpoint) read this and skip, because every one of them is ceremony
# aimed at a person in an interactive session.
#
# Exported here, in the ONE file all three runners source, for the same reason models.sh exists: a
# guard that is right in two runners and missing from the third is the same bug wearing a disguise.
#
# Not cosmetic. On 2026-07-16 a scout-extract run spent itself writing a SESSION REFLECTION into its
# own log, wrote a memory file into the project's store, and never wrote the results file the app was
# waiting for. Every extracted show was lost and the run still exited 0. The hooks fired because a
# headless `claude -p` inherits the same ~/.claude settings an interactive session does, and no CLI
# flag separates the two: --setting-sources drops the hooks but takes Dan's brand-voice skill with
# them, and --settings can only ADD hooks, never remove one. So the hooks check this instead.
export CLAUDE_DETACHED_RUN=1

# The app passes its build-specific handoff dir (Debug builds use an isolated Overture-Debug
# subfolder). Fall back to the live path for a hand-run from a terminal.
SUPPORT="${OVERTURE_SUPPORT_DIR:-$HOME/Library/Application Support/Overture}"

# open_run_log <log-filename>: open the log before any guard below can exit. The launching
# Process() redirects this whole invocation's stdout/stderr to /dev/null, so until #485 an
# early guard failure (no work-list, no claude CLI) left zero trace anywhere, identical to
# "ran and found nothing".
open_run_log() {
  mkdir -p "$SUPPORT"
  LOG="$SUPPORT/$1"
  exec >> "$LOG" 2>&1
}

# require_queue <queue-path> <label>: refuse to start if no work-list is present.
require_queue() {
  [ -f "$1" ] || { echo "no $2 queue at $1" >&2; exit 1; }
}

# resolve_claude: sets CLAUDE to a usable claude binary, or exits 1. The app launches these
# scripts with a minimal PATH, so look in the usual install spots rather than relying on PATH.
resolve_claude() {
  CLAUDE=""
  for c in "$HOME/.local/bin/claude" "/usr/local/bin/claude" "/opt/homebrew/bin/claude" "$(command -v claude 2>/dev/null || true)"; do
    if [ -n "$c" ] && [ -x "$c" ]; then CLAUDE="$c"; break; fi
  done
  [ -n "$CLAUDE" ] || { echo "claude CLI not found" >&2; exit 1; }
}
