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
# #1081: derives the "N of M" progress count from the results file itself (the SAME helper scout and prep
# use, #1015/#1023), so the reply drafter's label can never sit stuck at 0 just because the model forgot
# to self-report a count, which is exactly what silently failed for scout on 2026-07-16.
. "$(dirname "$0")/lib/progress-watcher.sh"
# #1038: the cooperative cancel check (the SAME predicates scout uses, #1037). Overture writes a
# cancel-request file; the heartbeat below checks for it each tick and stops the run cleanly. A detached
# run has no trackable PID (DetachedRunner backgrounds the whole script via `sh -c '... &'`), so a hard
# kill of the script is off the table; the stop is cooperative, and it lands at a poll boundary so it can
# never interrupt a reply mid-write and corrupt the shared results file.
. "$(dirname "$0")/lib/scout-cancel.sh"
# #1097: the fail-closed tool scope for this detached run, shared with scout-extract and prep.
# --allowedTools alone only PRE-approves; the --permission-mode manual this carries is what actually
# denies Bash, Edit, web access and everything else the inherited "auto" default would grant a headless run.
. "$(dirname "$0")/lib/claude-run-scope.sh"
# #1009: holds a no-idle-sleep power assertion (caffeinate) for the life of this detached run, so an
# idle-sleep timeout or a lid close cannot suspend or kill it mid run. Shared with the other two
# detached runners; released in the EXIT trap and, crash-safe, by caffeinate's own -w on this pid.
. "$(dirname "$0")/lib/sleep-guard.sh"
open_run_log "reply-classify-run.log"

# See lib/resolve-node.sh (#636): puts a real node on PATH before claude (and its hooks) launch.
. "$(dirname "$0")/lib/resolve-node.sh"

QUEUE="$SUPPORT/overture-reply-classify-queue.json"
RESULTS="$SUPPORT/overture-reply-classify-results.json"
PROGRESS="$SUPPORT/overture-reply-classify-progress.json"
RUNBOOK="$PROJECT_DIR/docs/reply-classify-runbook.md"
VOICE="$SUPPORT/overture-voice-guidance.md"
MARKER="$SUPPORT/reply-classify-running"

# #1038: the cooperative-cancel sentinel Overture writes to stop this run, and the file the heartbeat
# reads to know which claude process to stop when it sees the sentinel (the heartbeat is forked before
# claude launches, so it cannot see CLAUDE_PID directly; claude writes its PID here for it, mirroring
# scout-extract-run.sh's CHUNK_PIDS_FILE).
CANCEL="$SUPPORT/reply-classify-cancel"
CLAUDE_PID_FILE="$SUPPORT/reply-classify-claude-pid"
# A sentinel or PID left over from a previous cancelled run must never stop THIS one before it starts.
# Overture clears the sentinel too, before launching; this is defence in depth (assume-it-runs-twice).
clear_cancel "$CANCEL"
rm -f "$CLAUDE_PID_FILE" 2>/dev/null || true

require_queue "$QUEUE" "reply-classify"

# #1682: the scope needs the claude binary, because it asks it which plugins are installed on this Mac in
# order to name every one of them in the flag that turns them off. So the binary is resolved here rather
# than just before the launch a hundred lines below. It stays BELOW require_queue: "there is no work-list"
# is the more useful thing to find in the log, and it costs nothing to check first.
resolve_claude

# #1097: resolve the scope once and refuse to start if it has drifted unsafe (an auto-approving mode, or a
# forbidden tool like Bash or WebFetch in the allowlist). #1682 adds the second half: every Claude Code
# plugin installed on this Mac is turned off for the run, so no plugin's hooks can inject their own
# instructions into a prompt this repo wrote. Fail loud on either: a detached run that drafts replies to
# real people in Dan's voice must never fall back to a shell-capable posture, or to carrying a stranger's
# mandatory instructions, in silence.
REPLY_CLASSIFY_SCOPE="$(reply_classify_claude_scope "$CLAUDE")" || { echo "reply-classify: aborting, unsafe run scope" >&2; exit 1; }

# In-flight marker the app watches; removed on exit no matter what.
: > "$MARKER"

# #1081: seed a fresh progress file every run (never trust a leftover one from a prior run) so the reply
# drafter's "N of M" display starts correct even before any result has landed.
JQ="$(command -v jq 2>/dev/null || echo /usr/bin/jq)"
TOTAL="$("$JQ" '.items | length' "$QUEUE" 2>/dev/null || echo 0)"
printf '{"version":1,"total":%s,"completed":0}\n' "$TOTAL" > "$PROGRESS"

# Heartbeat: keep the marker fresh while working so a longer batch isn't mistaken for a crash.
#
# #1038: the loop also honours a cancel. The cancel is read on a SHORT poll (REPLY_CLASSIFY_CANCEL_POLL_SECONDS,
# default 3), DECOUPLED from the 60s marker touch by marker_due, so a Cancel Dan clicks stops the run (and
# its token spend) within a few seconds instead of up to a minute. When the sentinel is present the
# heartbeat stops the claude process it recorded and exits; the main script's `wait` then returns and it
# exits through normal cleanup. The kill lands at a poll boundary and never interrupts a results write, so
# no reply draft is corrupted mid-write.
#
# #1081: the marker tick also DERIVES progress from $RESULTS (the SAME update_progress_from_results scout
# and prep use), so the "N of M" count is a fact the script establishes by counting what has actually
# landed in the results file, never a number the model has to remember to self-report (which it forgot
# once, leaving scout's counter stuck at 0 through a live run on 2026-07-16). The derive runs only on the
# marker branch, so a cancel that lands on a plain cancel-poll tick never interrupts a results write.
CANCEL_POLL="${REPLY_CLASSIFY_CANCEL_POLL_SECONDS:-3}"
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
# CLAUDE_PID is filled in below once claude launches; killing it on exit stops a killed script from
# leaving an orphaned claude running against the queue.
CLAUDE_PID=""
# #1009: arm the sleep guard now, for the whole working duration, and release it in the trap below.
SLEEP_GUARD_PID="$(arm_sleep_guard)"
# #1038: clear the cancel sentinel and the pid file on exit too, so a stopped run never leaves a sentinel
# that would instantly kill the next run.
# #1009: stop_sleep_guard releases the power assertion on every exit path (finish, cancel, crash-via-set-e).
trap 'kill "$HEARTBEAT_PID" 2>/dev/null; [ -n "$CLAUDE_PID" ] && kill "$CLAUDE_PID" 2>/dev/null; stop_sleep_guard "$SLEEP_GUARD_PID"; rm -f "$MARKER"; clear_cancel "$CANCEL"; rm -f "$CLAUDE_PID_FILE"' EXIT

# #1013: the last run's results are spent, and leaving them here lets them masquerade as this run's.
# scout-extract-run.sh learned this in #1011 (a run that wrote nothing inherited the previous run's
# file wholesale, generatedAt and all); a stale reply-classify result carries a real draft that was
# never actually re-derived from this run's own replies.
discard_previous_results "$RESULTS"

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
verbatim so each result attaches to the right contact. Immediately after finishing EACH item, rewrite
$RESULTS with the complete v3 ReplyClassifyResults JSON (version 3; each result = {naturalKey,
recipientId, intent, draftSubject, draftBody}) covering EVERY item you have finished so far, not just
this one, and nothing else to that file. Do this after every single item, not only at the end: the app
derives its live 'N of M' progress from this file's own entry count, so the last time you do this simply
IS the end, and you must never wait until the whole work-list is done to write anything. If $VOICE is
absent, draft from the skill alone: it is the authority, and the
guidance file only ever nudges.
"

# Headless Claude Code run. Read (the work-list and the voice guidance), Write (the results), and #872:
# Skill, so this run can invoke dan-wright-brand-voice. Without that tool the prompt's instruction to use
# the skill is one the model cannot obey, and it would silently fall back to inventing his voice, which
# is exactly what it was doing before. Bash, Edit and web access are denied: $REPLY_CLASSIFY_SCOPE carries
# --permission-mode manual, so anything outside the allowlist is refused rather than auto-approved by the
# inherited settings (#1026/#1097). See lib/claude-run-scope.sh.
cd "$PROJECT_DIR"
# #868: the exit status is CAPTURED, never allowed to kill the script. Under `set -e` a claude that died
# took the whole script down with it, right here, before anything below could react.
#
# #1038: claude runs in the BACKGROUND now, with its PID recorded, so the heartbeat above can stop exactly
# this process on a cancel (the heartbeat was forked before this, so it cannot see CLAUDE_PID directly; the
# pid file hands it over, mirroring scout's chunk PIDs). `wait` blocks until claude finishes or the cancel
# kills it; either way its status is captured. Written as `|| ...` so a non-zero status (including the
# signal from a cancel) cannot trip `set -e` and take the whole script down on the failure path.
CLAUDE_STATUS=0
# shellcheck disable=SC2086  # $REPLY_CLASSIFY_SCOPE MUST word-split into --allowedTools <list> --permission-mode <mode>
"$CLAUDE" -p "$PROMPT" \
  --model "${OVERTURE_MODEL_REPLY_CLASSIFY}" \
  $REPLY_CLASSIFY_SCOPE &
CLAUDE_PID=$!
printf '%s' "$CLAUDE_PID" > "$CLAUDE_PID_FILE"
wait "$CLAUDE_PID" || CLAUDE_STATUS=$?
CLAUDE_PID=""   # reaped; nothing left for the trap to kill

# #1081: one last derive now that claude has exited, so the count reflects whatever landed between the
# previous heartbeat tick and the process actually finishing, rather than sitting stale.
update_progress_from_results "$QUEUE" "$RESULTS" "$PROGRESS"

# #868: a results file that does not parse is moved aside, so the app reports an empty run instead of
# failing to decode it in silence. Nothing is invented in its place: a fabricated intent would drive a
# conversation state off a decision no model ever made.
quarantine_unreadable_results "$RESULTS"

# #804: stamp what actually wrote this, so a draft can be traced to the model behind it.
record_model "$RESULTS" "${OVERTURE_MODEL_REPLY_CLASSIFY}"

echo "reply-classify run finished (claude exit ${CLAUDE_STATUS}) -> $RESULTS"
exit "$CLAUDE_STATUS"
