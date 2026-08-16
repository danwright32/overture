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
# #2763: which set of files this run owns. Sourced immediately after runner-setup, which is what defines
# SUPPORT, and BEFORE open_run_log, whose own filename comes from the slot. An absent slot means prep, so
# an older app that names none launches exactly the run it always did.
. "$(dirname "$0")/lib/run-slot.sh"
resolve_run_slot
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
# #2106: the heartbeat touch, and stopping the run when it can no longer report itself alive.
. "$(dirname "$0")/lib/run-heartbeat.sh"
# #2506: the other half of that question. A fresh marker proves the watchdog is alive, never that the
# work is progressing, so the heartbeat also asks whether anything new has landed lately and stops a run
# that has stood still too long. See lib/run-stall-guard.sh.
. "$(dirname "$0")/lib/run-stall-guard.sh"
# #1097: the fail-closed tool scope for this detached run, shared with scout-extract and reply-classify.
# --allowedTools alone only PRE-approves; the --permission-mode manual this carries is what actually
# denies Edit and everything else the inherited "auto" default would otherwise grant a headless run.
. "$(dirname "$0")/lib/claude-run-scope.sh"
# #1009: holds a no-idle-sleep power assertion (caffeinate) for the life of this detached run, so an
# idle-sleep timeout or a lid close cannot suspend or kill it mid draft. Shared with the other two
# detached runners; released in the EXIT trap and, crash-safe, by caffeinate's own -w on this pid.
. "$(dirname "$0")/lib/sleep-guard.sh"
# #1597: the split/merge used to run a reachability check as up to 10 concurrent claudes. The SAME two
# functions scout-extract has used since #1028, parameterised for this queue's `naturalKey` and results
# version rather than copied, so a fix to either one lands in both runners.
. "$(dirname "$0")/lib/scout-parallel.sh"
open_run_log "$SLOT_LOG_NAME"

# See lib/resolve-node.sh (#636): puts a real node on PATH before claude (and its hooks) launch.
. "$(dirname "$0")/lib/resolve-node.sh"

QUEUE="$SLOT_QUEUE"
RESULTS="$SLOT_RESULTS"
PROGRESS="$SLOT_PROGRESS"
RUNBOOK="$PROJECT_DIR/docs/prep-runbook.md"
# #2764: the voice artifacts, from the resolver like everything else, so this script names no handoff
# path itself. Deliberately shared rather than slot-scoped: see run-slot.sh.
VOICE_FEEDBACK="$SHARED_VOICE_FEEDBACK"
RECENT_OPENERS="$SHARED_RECENT_OPENERS"
VOICE_GUIDANCE="$SHARED_VOICE_GUIDANCE"
# #1593: the raw stream-json events, kept beside the run log so the cost can be read after the run. The
# log stays human-readable; this file is the machine copy nobody reads by hand.
EVENTS="$SLOT_EVENTS"
MARKER="$SLOT_MARKER"

# #1597: a reachability CHECK is chunked; a normal Prep run is not, and the difference is not a
# performance preference. The prompt's once-per-run voice-learning step rewrites
# overture-voice-guidance.md, and several claudes doing that at the same time would race on one file.
# A check never drafts, so it does not need that step at all: the chunked prompt omits it, which
# removes the race rather than trying to coordinate around it.
#
# The probe marker is the app's own authoritative "this run is a check" signal (the same file
# settleReachabilityProbe reads), so the two can never disagree about which kind of run this is.
# #2763: NOT slot-derived, deliberately, and the only run file that is not. This marker is how the app
# and this script agree that the run is a check, and moving run identity onto the slot is #2760's job, not
# this phase's. Deriving IS_PROBE from the slot here while the app still launches every run as `prep`
# would make a check run unchunked on the drafting model, which is the opposite of behaviour unchanged.
PROBE_MARKER="$SUPPORT/reachability-probe-run.json"
IS_PROBE=0
[ -f "$PROBE_MARKER" ] && IS_PROBE=1
CHUNKDIR="$SLOT_CHUNKDIR"
# Wipe before anything reads it: a leftover chunk-results file from a previous, larger check must never
# be merged into this run as if it were this run's work. Assume-it-runs-twice.
#
# #2763: through the shared helper, and slot-scoped. Unscoped, a starting check would delete a live
# prep's chunk logs and destroy its in-flight chunk results, which merge_chunk_results folds into the
# app's results file on every heartbeat tick.
slot_wipe_chunk_files
MAX_PARALLEL="${OVERTURE_PREP_MAX_PARALLEL:-10}"
# #1597: a CHECK finds contacts and never drafts, so it runs on the cheaper model the eval measured as
# rule-clean. A normal Prep run writes emails in Dan's voice and stays on the pinned drafting model.
if [ "$IS_PROBE" = "1" ]; then
  RUN_MODEL="${OVERTURE_MODEL_REACHABILITY}"
else
  RUN_MODEL="${OVERTURE_MODEL_DRAFTING}"
fi

# #1038: the cooperative-cancel sentinel Overture writes to stop this run, and the file the heartbeat
# reads to know which claude process to stop when it sees the sentinel. The heartbeat is forked before
# claude launches, so it cannot see CLAUDE_PID directly; claude writes its PID here for it (mirrors
# scout-extract-run.sh's CHUNK_PIDS_FILE).
CANCEL="$SLOT_CANCEL"
CLAUDE_PID_FILE="$SLOT_CLAUDE_PID"
# A sentinel or PID left over from a previous cancelled run must never stop THIS one before it starts.
# Overture clears the sentinel too, before launching; this is defence in depth (assume-it-runs-twice).
clear_cancel "$CANCEL"
rm -f "$CLAUDE_PID_FILE" 2>/dev/null || true

# #2506: where the stall guard keeps how long this run has stood still, and how long standing still is
# allowed to last. Removed here as well as in the trap, so a previous run's accrued stall time can never
# be inherited and stop this one early (assume-it-runs-twice).
#
# 20 minutes is sized well past anything this run has ever done. The first real reachability check took
# 7m51s for THREE shows (about 2m40s per show), and a Prep run lands a result per show as it goes, so on a
# healthy run something new lands every few minutes at worst. Dan-tunable, and an unset or mistyped value
# disables the ceiling rather than shortening it.
STALL_STATE="$SLOT_STALL_STATE"
STALL_LIMIT="${PREP_STALL_LIMIT_SECONDS:-1200}"
rm -f "$STALL_STATE" 2>/dev/null || true

require_queue "$QUEUE" "prep"

# #1682: the scope needs the claude binary, because it asks it which plugins are installed on this Mac in
# order to name every one of them in the flag that turns them off. So the binary is resolved here rather
# than just before the launch hundreds of lines below. It stays BELOW require_queue: "there is no
# work-list" is the more useful thing to find in the log, and it costs nothing to check first.
resolve_claude

# #1097: resolve the scope once and refuse to start if it has drifted unsafe (an auto-approving mode, or
# Edit smuggled into the allowlist). #1682 adds the second half: every Claude Code plugin installed on
# this Mac is turned off for the run, so no plugin's hooks can inject their own instructions into a
# prompt this repo wrote. Fail loud on either: a detached run that drafts emails reaching strangers in
# Dan's voice must never fall back to a shell-and-edit posture, or to carrying a stranger's mandatory
# instructions, in silence.
PREP_SCOPE="$(prep_claude_scope "$CLAUDE")" || { echo "prep: aborting, unsafe run scope" >&2; exit 1; }

# In-flight marker the app can watch (issue #44); removed on exit no matter what.
: > "$MARKER"

# #354: seed a fresh progress file every run (never trust a leftover one from a prior run) so
# the app's "N of M" display starts correct even before any result has landed.
JQ="$(command -v jq 2>/dev/null || echo /usr/bin/jq)"
# #1597: SHOWS, not queue entries, matching update_progress_from_results. A grouped item answers for the
# keys in its alsoAnswersFor, so the item count would seed "0 of 4" for a check Dan started on six shows.
TOTAL="$("$JQ" '[.items[] | 1 + ((.alsoAnswersFor // []) | length)] | add // 0' "$QUEUE" 2>/dev/null || echo 0)"
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
  # #2109: any way this loop ends stops the run, including a `set -e` death on a bookkeeping
  # command. See lib/run-heartbeat.sh.
  heartbeat_guard_exit "$CLAUDE_PID_FILE"
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
      # #2106: cannot report itself alive => stops the run. Why, in lib/run-heartbeat.sh.
      heartbeat_touch_or_stop "$MARKER" "$CLAUDE_PID_FILE" || exit
      # #1597: fold whatever the chunks have written so far into the one results file the app polls,
      # BEFORE deriving the count from it, so "N of M" climbs during a chunked run exactly as it does
      # during a sequential one. A no-op when there are no chunk files (every normal Prep run).
      # #2109: non-fatal. A run whose progress count failed to update is still ALIVE and
      # must keep beating; killing a paid run over a counting hiccup is the wrong trade.
      merge_chunk_results "$QUEUE" "$CHUNKDIR" "$RESULTS" naturalKey 6 || true
      update_progress_from_results "$QUEUE" "$RESULTS" "$PROGRESS" || true
      # #2506: and the question the touch above cannot answer. Deliberately NOT guarded with `|| true`
      # like the bookkeeping call above: its non-zero return IS the verdict, and swallowing it would leave
      # the run doing exactly what scout-extract did on 2026-08-11.
      if ! stall_tick "$RESULTS" "$STALL_STATE" "$MARKER_INTERVAL" "$STALL_LIMIT"; then
        echo "prep: STOPPING. Nothing new has landed for $(stall_stalled_seconds "$STALL_STATE")s (limit ${STALL_LIMIT}s), so this run is not progressing however fresh its marker is. Everything it never reported is written down as unreported below."
        exit
      fi
      STALLED_FOR="$(stall_stalled_seconds "$STALL_STATE")" || STALLED_FOR=0
      [ "$STALLED_FOR" = "0" ] || echo "prep: nothing new has landed for ${STALLED_FOR}s (stopping at ${STALL_LIMIT}s)"
    fi
  done ) &
HEARTBEAT_PID=$!
# CLAUDE_PID is filled in below once claude launches; killing it on exit stops a killed script (Dan
# quits the app, a crash) from leaving an orphaned claude running against the queue.
CLAUDE_PID=""
# #1009: arm the sleep guard now, for the whole working duration, and release it in the trap below.
SLEEP_GUARD_PID="$(arm_sleep_guard)"
# #1038: clear the cancel sentinel and the pid file on exit too, so a stopped run never leaves a sentinel
# that would instantly kill the next run.
# #1009: stop_sleep_guard releases the power assertion on every exit path (finish, cancel, crash-via-set-e).
# #2764: `slot_check_foreign_results` is in the TRAP, not at the end of the script, because the script
# ends with `exit "$CLAUDE_STATUS"` and a line after that is dead code. The trap is the only place that
# runs on every exit path there is: finished, cancelled, stalled out, killed with the app.
trap 'kill "$HEARTBEAT_PID" 2>/dev/null; [ -n "$CLAUDE_PID" ] && kill "$CLAUDE_PID" 2>/dev/null; stop_sleep_guard "$SLEEP_GUARD_PID"; rm -f "$MARKER"; clear_cancel "$CANCEL"; rm -f "$CLAUDE_PID_FILE"; rm -f "$STALL_STATE"; slot_check_foreign_results || true' EXIT

# #1013: the last run's results are spent, and leaving them here lets them masquerade as this run's.
# scout-extract-run.sh learned this in #1011 (a run that wrote nothing inherited the previous run's
# file wholesale, generatedAt and all); prep is the worse place for the same bug, since a stale result
# carries real contacts and drafted email text.
discard_previous_results "$RESULTS"

# #2764: fingerprint the other slot's results BEFORE the run starts, so the check at the end has
# something to compare against. See slot_check_foreign_results in lib/run-slot.sh.
slot_record_foreign_results

# #2764: the paths in this prompt are the ONLY ones. The runbook is a prompt too, and Write is a granted
# tool, so a path written in prose there competes with these. It no longer states any, and this line is
# what settles it if one ever comes back.
PATHS_RULE="The file paths in THIS prompt are the only ones. Ignore any literal path written anywhere
else, including in the runbook: read and write exactly the paths given here and no others."

PROMPT="You are the Overture Prep run. Follow $RUNBOOK exactly. $PATHS_RULE FIRST, once per run, do the
'Learn from Dan's recent edits' step: read $VOICE_FEEDBACK if present and update
the anonymized auto-generated section of $VOICE_GUIDANCE (strip all org/venue/contact
specifics; never carry them into other drafts). The cross-run openers to avoid reusing are in
$RECENT_OPENERS, when it is present. Then read the work-list at $QUEUE, and for every
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

# #1597: the prompt for a reachability CHECK. Deliberately not the Prep prompt with a flag: it omits the
# once-per-run voice-learning step entirely, because a check never drafts (so the step buys nothing) and
# because up to ten concurrent chunks each rewriting overture-voice-guidance.md would race on one file.
# Removing the step removes the race, rather than trying to coordinate ten writers around it.
PROBE_PROMPT="You are the Overture reachability check. Follow $RUNBOOK exactly, the contact-finding
half only. $PATHS_RULE Read the work-list at $QUEUE and for every item find the contact (waterfall, strict
verification). Do NOT draft any email and do NOT emit a draft field on any result: every item is
contacts_only. Copy each item's naturalKey verbatim. If an item carries alsoAnswersFor, research its
contact ONCE and write that same contacts list into a separate result entry for the item's own
naturalKey AND for every key listed there, copying each key byte-for-byte. Immediately after finishing
EACH item, rewrite $RESULTS with the complete PrepResults JSON covering EVERY item you have finished so
far, not just this one. Do this after every single item, not only at the end: the app derives its live
'N of M' progress from this file's own entry count. Write the complete PrepResults JSON to $RESULTS and
nothing else to that file. This run is DETACHED: nobody can answer you, so never stop to ask, decide and
record the decision in the result. Do the web research needed to find real, verifiable contacts.
"

# Headless Claude Code run. Read, Write, WebSearch, WebFetch, Bash and Skill (the six tools this run's
# job needs); Edit and everything else are denied because $PREP_SCOPE carries --permission-mode manual,
# so anything outside the allowlist is refused rather than auto-approved by the inherited settings
# (#1026/#1097). See lib/claude-run-scope.sh.
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
# shellcheck disable=SC2086  # $PREP_SCOPE MUST word-split into --allowedTools <list> --permission-mode <mode>
#
# #1593: --output-format stream-json --verbose is what makes the run's cost readable afterwards. Its
# stdout is raw JSON, so it goes through tee_run_events: the raw stream to $EVENTS for parsing, a
# readable trickle to this log so a run that takes minutes still looks alive.
#
# Through a NAMED PIPE, not process substitution. This script declares `#!/bin/sh` and the app launches
# it with /bin/sh (DetachedRunner), which on macOS is bash in POSIX mode, where `> >(...)` does not
# exist. The first real reachability check died instantly on exactly that: "syntax error near unexpected
# token `>`", caught by nothing because `bash -n` accepts it and no test ran the script through the shell
# that launches it. scripts/check-runner-posix.sh now does.
#
# The reader is started FIRST so opening the pipe for writing does not block, and claude stays the
# directly backgrounded process, so `$!` is still ITS pid and the #1038 cooperative cancel keeps working.

# run_one_claude <prompt> <events-file> <fifo-path> [log-file]
#
# One claude, its stdout captured through a named pipe so the raw stream is parseable for cost while a
# readable trickle still reaches a log. Factored out because the chunked path needs the identical dance
# up to 10 times over, and two copies of a pipe-and-reap sequence is exactly where the two would drift.
# Prints nothing; sets CLAUDE_ONE_PID for the caller to record and wait on.
run_one_claude() {
  _prompt="$1"; _events="$2"; _fifo="$3"; _log="${4:-}"
  rm -f "$_fifo"
  mkfifo "$_fifo" || echo "prep: could not create the event pipe; cost will not be recorded" >&2
  if [ -n "$_log" ]; then
    tee_run_events "$_events" < "$_fifo" >> "$_log" 2>&1 &
  else
    tee_run_events "$_events" < "$_fifo" &
  fi
  _tee_pid=$!
  # shellcheck disable=SC2086  # $PREP_SCOPE MUST word-split into --allowedTools <list> --permission-mode <mode>
  "$CLAUDE" -p "$_prompt" \
    --model "${RUN_MODEL}" \
    --output-format stream-json --verbose \
    $PREP_SCOPE > "$_fifo" &
  CLAUDE_ONE_PID=$!
  CLAUDE_ONE_TEE_PID=$_tee_pid
  CLAUDE_ONE_FIFO=$_fifo
}

# reap_one_claude <pid> <tee-pid> <fifo>: wait for claude, then for the reader (claude's exit closes the
# write end, so the reader sees EOF), then remove the pipe. Sets REAPED_STATUS.
#
# Sets a variable rather than echoing its result, and MUST NOT be called in a command substitution:
# that is a subshell, and a subshell cannot `wait` on a process belonging to its parent. Written the
# echoing way first, `wait` returned instantly without waiting for anything, so the script raced past a
# claude that was still working, read an empty event stream, and recorded no cost at all for the run.
reap_one_claude() {
  REAPED_STATUS=0
  wait "$1" || REAPED_STATUS=$?
  wait "$2" 2>/dev/null || true
  rm -f "$3"
}

EVENTS_FIFO="$SLOT_EVENTS_FIFO"

if [ "$IS_PROBE" = "1" ]; then
  # #1597: a reachability check runs as up to MAX_PARALLEL concurrent claudes, one per chunk of the
  # work-list. The shows are wholly independent (each is its own contact hunt), so this cuts wall clock
  # roughly in proportion to the chunk count: the first real check took 7m51s for three shows
  # sequentially, and three concurrent chunks finish in about the time of the slowest single show.
  #
  # split_queue_into_chunks never makes an empty chunk, so a night with fewer shows than the cap simply
  # gets one claude per show. The cap is a ceiling, not a target: it exists because each claude is a live
  # web-fetching process, and past ten at once the plan's rate limit and this Mac both start to suffer,
  # at which point retries make a parallel run slower than the sequential one it replaced.
  mkdir -p "$CHUNKDIR" 2>/dev/null || true
  CHUNK_COUNT="$(split_queue_into_chunks "$QUEUE" "$MAX_PARALLEL" "$CHUNKDIR")"
else
  CHUNK_COUNT=0
fi

if [ "${CHUNK_COUNT:-0}" -ge 1 ]; then
  echo "prep: reachability check split into $CHUNK_COUNT chunk(s), running concurrently"
  CHUNK_PIDS=""
  CHUNK_TEE_PIDS=""
  # The event files are accumulated as POSITIONAL PARAMETERS, not as a space-separated string.
  #
  # A string was the first shape, and it silently broke cost capture on the very first real chunked run:
  # the support directory is "~/Library/Application Support/Overture", so unquoted word-splitting cut
  # every path in half at that space. record_run_cost was handed 8 arguments that were not files instead
  # of 4 that were, found no cost envelope in any of them, and honestly reported "not recorded" for a run
  # that had reported its cost perfectly. `set --` is the only way a POSIX shell can carry a list of
  # paths that may contain spaces.
  set --
  k=1
  while [ "$k" -le "$CHUNK_COUNT" ]; do
    CHUNK_LOG="$(slot_chunk_log "$k")"
    CHUNK_EVENTS="$(slot_chunk_events "$k")"
    : > "$CHUNK_LOG"
    # Only the two paths change per chunk: each claude reads its own slice and writes its own results
    # file, never a shared one, which concurrent incremental rewrites would clobber.
    CHUNK_PROMPT="${PROBE_PROMPT//$QUEUE/$CHUNKDIR/chunk-queue-$k.json}"
    CHUNK_PROMPT="${CHUNK_PROMPT//$RESULTS/$CHUNKDIR/chunk-results-$k.json}"
    run_one_claude "$CHUNK_PROMPT" "$CHUNK_EVENTS" "$(slot_chunk_fifo "$k")" "$CHUNK_LOG"
    CHUNK_PIDS="$CHUNK_PIDS $CLAUDE_ONE_PID"
    CHUNK_TEE_PIDS="$CHUNK_TEE_PIDS $CLAUDE_ONE_TEE_PID"
    set -- "$@" "$CHUNK_EVENTS"
    k=$((k + 1))
  done
  # #1038: the heartbeat was forked before these launched, so it cannot see CHUNK_PIDS. The pid file is
  # how a Cancel reaches exactly these processes; it already word-splits, so several pids need no change
  # on the heartbeat side.
  printf '%s' "$CHUNK_PIDS" > "$CLAUDE_PID_FILE"
  CLAUDE_PID="$CHUNK_PIDS"   # so the EXIT trap kills every chunk, not just one

  # Wait for every chunk, capturing each status so one failure is recorded without hiding the others.
  # The first non-zero becomes the run's status. Written as `||` so a chunk exiting non-zero cannot trip
  # `set -e` and take down the merge, which is what carries home the work the OTHER chunks completed.
  for pid in $CHUNK_PIDS; do
    st=0
    wait "$pid" || st=$?
    if [ "$st" != "0" ] && [ "$CLAUDE_STATUS" = "0" ]; then CLAUDE_STATUS="$st"; fi
  done
  for tpid in $CHUNK_TEE_PIDS; do wait "$tpid" 2>/dev/null || true; done
  # The pipe paths are REBUILT from the chunk number, never carried in a space-separated string. Held as
  # a string they word-split inside "Application Support" and every removal missed, leaving a named pipe
  # behind for each chunk. The PID lists above are safe as strings only because a PID has no spaces.
  k=1
  while [ "$k" -le "$CHUNK_COUNT" ]; do
    rm -f "$(slot_chunk_fifo "$k")"
    k=$((k + 1))
  done
  CLAUDE_PID=""   # all reaped; nothing left for the trap to kill

  # Fold each chunk's log tail into the main log, so the reason a chunk failed travels with the run.
  k=1
  while [ "$k" -le "$CHUNK_COUNT" ]; do
    echo "--- chunk $k log tail ---"
    tail -n 4 "$(slot_chunk_log "$k")" 2>/dev/null || true
    k=$((k + 1))
  done

  # The final merge, now every chunk has exited, so $RESULTS reflects the last writes each chunk made
  # between the previous heartbeat tick and finishing.
  merge_chunk_results "$QUEUE" "$CHUNKDIR" "$RESULTS" naturalKey 6
else
  run_one_claude "$PROMPT" "$EVENTS" "$EVENTS_FIFO"
  CLAUDE_PID="$CLAUDE_ONE_PID"
  printf '%s' "$CLAUDE_PID" > "$CLAUDE_PID_FILE"
  reap_one_claude "$CLAUDE_ONE_PID" "$CLAUDE_ONE_TEE_PID" "$CLAUDE_ONE_FIFO"
  CLAUDE_STATUS="$REAPED_STATUS"
  CLAUDE_PID=""   # reaped; nothing left for the trap to kill
  set -- "$EVENTS"
fi

# #1023: one last derive now that claude has exited, so the count reflects whatever landed between the
# previous heartbeat tick and the process actually finishing, rather than sitting stale.
update_progress_from_results "$QUEUE" "$RESULTS" "$PROGRESS"

# #868: if the run wrote a results file that does not parse, move it aside. Left where it is, the app
# reads a FRESH file as a run that produced results, its decode fails, and it says nothing at all. Moved,
# the run reports as what it was, with the tail of this log. Prep is the worst place for that silence:
# this is the run that finds the contacts and writes the drafts.
quarantine_unreadable_results "$RESULTS"

# #804: stamp what actually wrote this, so a draft can be traced to the model behind it.
record_model "$RESULTS" "${RUN_MODEL}"

# #1593: and what it cost, from the final result envelope in the event stream. A run that died or was
# cancelled leaves no envelope, and that is recorded as "not recorded" rather than as zero, so a batch
# ceiling can never be sized against a number nobody measured.
# Quoted "$@", so a path containing a space stays ONE argument.
record_run_cost "$RESULTS" "$@"

# #1721: and how many times it actually reached the web, counted from the SAME streams rather than taken
# on trust from the runbook's hop cap. Runs after record_run_cost and reads the same "$@", so the two
# numbers describing one run can never be derived from different sets of streams.
#
# The default cap is per SHOW and deliberately well clear of normal: Dan's 2026-07-28 run measured 5 to 9
# web calls per show, and #1720 will make each lookup deeper still by following a named organisation to
# its own site. A cap that fires on an ordinary run is an alert that cries wolf (L36), so this is set to
# catch a runaway, not to police a thorough hunt. Overridable so the ceiling can be tightened without a
# code change once #1720's real depth is measured.
record_web_calls "$RESULTS" "${OVERTURE_PREP_WEB_CALL_CAP:-15}" "$@"

echo "prep run finished (claude exit ${CLAUDE_STATUS}) -> $RESULTS"
exit "$CLAUDE_STATUS"
