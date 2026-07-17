#!/bin/sh
# Scout-extract runner: launched DETACHED by the Overture app when a watched source's listings page
# has changed (or when Dan hands it a new lead). Drives a Claude Code run on Dan's Max plan that reads
# the PINNED pages the app already fetched, extracts the upcoming events, and writes the results file
# the app ingests. Runs headless; the app does not supervise it.
#
# Configure the app to point at this script: set the UserDefaults key 'scoutExtractRunnerScriptPath'
# to this file's path, and chmod +x it. See docs/scout-extract-runbook.md.

set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)/.."   # the Overture repo root

# See lib/runner-setup.sh (#552): shared support-dir resolution, log redirection, and early-guard
# structure with prep-run.sh and reply-classify-run.sh.
. "$(dirname "$0")/lib/runner-setup.sh"
# #804: which model this run uses, and the helper that records it. One place, so a model choice
# cannot be right in two runners and wrong in the third.
. "$(dirname "$0")/lib/models.sh"
# #856: the guarantee that this run cannot vanish. Every queued source comes back with a result, even
# when the model writes none.
. "$(dirname "$0")/lib/results-guard.sh"
# #1015: derives the "N of M" progress count from the results file itself, so the toolbar can never
# show a stale count just because the model forgot to report one.
. "$(dirname "$0")/lib/progress-watcher.sh"
# #1028: split the queue into chunks and merge the per-chunk results, so the sources can be read
# concurrently instead of in one long sequential pass. The app still sees one queue, one progress file,
# and one results file: chunking lives entirely in this runner.
. "$(dirname "$0")/lib/scout-parallel.sh"
# #1037: the cooperative cancel check. Overture writes a cancel-request file; the heartbeat below checks
# for it each tick and stops the run cleanly. A detached read has no trackable PID, so a hard kill is off
# the table; a cooperative stop between ticks also can never interrupt a source mid-write and corrupt the
# shared results file the way a kill -9 could.
. "$(dirname "$0")/lib/scout-cancel.sh"
open_run_log "scout-extract-run.log"

# See lib/resolve-node.sh (#636): puts a real node on PATH before claude (and its hooks) launch.
. "$(dirname "$0")/lib/resolve-node.sh"

QUEUE="$SUPPORT/overture-scout-extract-queue.json"
RESULTS="$SUPPORT/overture-scout-extract-results.json"
PROGRESS="$SUPPORT/overture-scout-extract-progress.json"
RUNBOOK="$PROJECT_DIR/docs/scout-extract-runbook.md"
MARKER="$SUPPORT/scout-extract-running"

# #1028: where the split queue and the per-chunk results live. A scratch dir under the handoff dir, never
# read by the app: only this runner writes here, and it is wiped and rebuilt every run so a bigger
# previous run's chunk files can never masquerade as this run's work.
CHUNKDIR="$SUPPORT/scout-extract-chunks"

# #1037: the cooperative-cancel sentinel Overture writes to stop this run, and the file the heartbeat
# reads to know which chunk processes to stop when it sees the sentinel (the heartbeat is forked before
# the chunks launch, so it cannot see CHUNK_PIDS directly; the chunks write their PIDs here for it).
CANCEL="$SUPPORT/scout-extract-cancel"
CHUNK_PIDS_FILE="$SUPPORT/scout-extract-chunk-pids"
# A sentinel left over from a previous cancelled run must never stop THIS one before it starts. Overture
# clears it too, before launching; this is defence in depth (assume-it-runs-twice).
clear_cancel "$CANCEL"
rm -f "$CHUNK_PIDS_FILE" 2>/dev/null || true

# How many claude processes read the queue at once. Bounded and Dan-tunable: the total token work is
# unchanged (the same pages, the same detail fetches), it is just done concurrently, so this trades a
# shorter wait against more simultaneous load on the Max plan. Default 4 turns a 16-minute wait into
# roughly 4. Set to 1 to fall straight back to the old single-process sequential run.
MAX_PARALLEL="${SCOUT_EXTRACT_MAX_PARALLEL:-4}"

require_queue "$QUEUE" "scout-extract"

# In-flight marker the app watches; removed on exit no matter what.
: > "$MARKER"

# Heartbeat: keep the marker fresh while working, so a legitimately long batch (several pages, each
# with detail pages to follow) is never mistaken for a crash and freed for a second run to clobber.
#
# #1015: the SAME tick also derives progress from $RESULTS, rather than a second background loop.
# This is what makes the "N of M" toolbar count a fact the script establishes on its own: it counts
# what has actually landed in the results file, so it can never sit at 0 just because the model never
# got around to reporting a count (2026-07-16's run never did).
#
# #1028: the tick first MERGES the per-chunk results into $RESULTS, so the file the app polls is the
# live union of every chunk's work and the derived count advances across all chunks at once. When the
# run is not chunked (a node-free machine falls back to a single process writing $RESULTS directly),
# merge_chunk_results finds no chunk files and no-ops, and the derive reads $RESULTS as before.
# #1037: the SAME tick also honours a cancel. When Overture has written the sentinel, the heartbeat
# stops the chunk processes it recorded (a cooperative stop, so no source is interrupted mid-write) and
# exits; the main script's `wait` then returns, and it exits through its normal cleanup. Checked right
# after touching the marker so a cancel is noticed within one tick.
( while :; do
    sleep 60
    touch "$MARKER" 2>/dev/null || exit
    if cancel_requested "$CANCEL"; then
      # shellcheck disable=SC2046
      [ -s "$CHUNK_PIDS_FILE" ] && kill $(cat "$CHUNK_PIDS_FILE" 2>/dev/null) 2>/dev/null
      exit
    fi
    merge_chunk_results "$QUEUE" "$CHUNKDIR" "$RESULTS"
    update_progress_from_results "$QUEUE" "$RESULTS" "$PROGRESS"
  done ) &
HEARTBEAT_PID=$!
# CHUNK_PIDS is filled in below once the chunk processes launch; killing them on exit stops a killed
# script (Dan quits the app, a crash) from leaving orphaned claude processes running against the queue.
CHUNK_PIDS=""
# #1037: clear the cancel sentinel and the pids file on exit too, so a stopped run never leaves a
# sentinel that would instantly kill the next run.
trap 'kill "$HEARTBEAT_PID" 2>/dev/null; [ -n "$CHUNK_PIDS" ] && kill $CHUNK_PIDS 2>/dev/null; rm -f "$MARKER"; clear_cancel "$CANCEL"; rm -f "$CHUNK_PIDS_FILE"' EXIT

# #1011: the last run's results are spent, and leaving them here lets them masquerade as this run's.
# Before this, a run that wrote nothing inherited the previous run's file wholesale, generatedAt and
# all, and the app ingested hours-old results as the answer to a queue written minutes ago.
discard_previous_results "$RESULTS"

# Seed the progress file so the app shows "0 of N" immediately rather than a bare spinner while the
# run boots (a cold Claude Code start is not instant). The heartbeat above (and the derive right
# after claude exits) is what advances it from here; #1015 made this the script's own job, never the
# model's to self-report.
TOTAL=$(grep -c '"sourceId"' "$QUEUE" 2>/dev/null || echo 0)
printf '{"version":1,"total":%s,"completed":0}\n' "$TOTAL" > "$PROGRESS"

PROMPT="You are the Overture scout-extract run (v1). Follow $RUNBOOK exactly. Read the work-list at
$QUEUE. TODAY'S DATE matters: only report performances that are today or later.

For EVERY item in the work-list:
  1. Read the pinned page at that item's pagePath. It is normalized HTML: scripts, styles and
     attribute noise are stripped, but the tag structure (INCLUDING TABLES AND CELLS) and links are
     intact. Some calendars print no dates at all and put each concert in a cell of a month grid, so
     the date is implied by WHICH cell it sits in and by the month heading. Read the grid.

     If a single read of the pinned file does not return the whole thing (the tool tells you there is
     more, or offers an offset to continue), keep reading with an increasing offset until you have
     covered the ENTIRE file before you extract anything. Do not extract from, or judge, a file you
     have only partly seen. Only report incomplete_extraction (step 4) if you truly cannot get past a
     hard limit after doing this.
  2. Extract every UPCOMING performance. Do NOT invent anything that is not on the page. A page whose
     listings are all in the past is a normal, healthy state (an organization between seasons); report
     it honestly rather than reaching for something to return.
  3. The listings page usually does NOT carry the venue, and sometimes not the year. Both are on each
     event's own detail page. FOLLOW the event's link (WebFetch) to get the venue and the exact date.
     Overture needs the venue: it drives classification and the pitch itself. Never guess a venue.
  4. Judge the PAGE and report exactly one verdict for it:
       upcoming_listings     it has upcoming performances (you are returning them)
       all_past              it has dated listings, but every one has already happened
       no_dated_content      it carries no dated listings at all (often the wrong page entirely)
       unreadable            the bytes carry no event data (e.g. a calendar drawn by JavaScript, or a
                             login wall). Say so; do not pretend to have read it.
       incomplete_extraction the page is larger than you could read even after paging through it with
                             offset (step 1). Return whatever events you found in the part you DID
                             read, and say in the note that the page was too large to finish. Only use
                             this after actually trying to read the rest of the file; do not reach for
                             it just because the first read was truncated.
  5. PAGINATION: NEVER follow a link to another listings page (/P20, ?page=2, a next-month link). The app
     has already fetched every page you are meant to read, and it hands them to you in the pinned file.
     A pinned page may therefore contain SEVERAL MONTHS of one calendar, each wrapped in a section under
     a marker comment naming it:

         <!-- overture-month 2026-10 https://example.org/calendar/2026/10/ -->

     Read EVERY marked section and return the shows from ALL of them, as one set for that one sourceId.
     Do not stop at the first section, and do not report it as page 1 of N.

     Following links yourself is forbidden for a reason that has not changed: the app hashes the bytes it
     fetched, so anything you wander off to find is not part of the set it reconciles against, and a run
     that wanders across an unbounded number of pages is the one that never comes back. (Following each
     EVENT's own detail page, per step 3, is different and still required.)
  6. Immediately after finishing THIS item, rewrite $RESULTS with the complete v1 ScoutExtractResults
     JSON covering EVERY item you have finished so far, not just this one. Do this after every single
     item, not only at the very end: the app watches this file to show real progress as you work, and
     the last time you do this simply IS the end. Never wait until the whole work-list is done to write
     anything.

YOU MUST ALWAYS have written $RESULTS before you finish, covering every item, not just the last one.
This run is DETACHED: nobody is reading your output and nobody can answer you. A question is not an
output. Never stop to ask which of two things to do: decide, do it, and record the decision in that
source's "note" field. If you are unsure, a result with a verdict and an honest note is worth
everything, and a question is worth nothing, because the work is thrown away and the app is left
waiting for a file that never arrives. That has already happened once: twenty correctly extracted
shows were lost to a question about pagination.

Copy each item's sourceId VERBATIM into its result. Never rebuild it: a reconstructed id matches
nothing on the way home and the work vanishes silently.

The v1 ScoutExtractResults JSON, in full, is what you write to $RESULTS and nothing else to that
file, every time, growing as you go:
{\"version\":1,\"generatedAt\":\"<ISO8601>\",\"results\":[{\"sourceId\":\"...\",\"verdict\":\"...\",
\"events\":[{\"title\":\"...\",\"presenter\":\"...\",\"venue\":\"...\",\"performanceDate\":\"YYYY-MM-DD\",
\"sourceUrl\":\"...\"}],\"note\":\"one short line on anything that made this hard\"}]}
"

resolve_claude

# Headless Claude Code run(s). Read (the pinned pages), Write (results + progress), WebFetch (each
# event's detail page, for the venue and exact date, which the listings page usually lacks). No Bash, no
# Skill, no WebSearch: this run reads files, follows links it was given, and writes two files.
#
# #1028: the queue is split into up to MAX_PARALLEL contiguous chunks and one claude drives each,
# concurrently. Every source is in exactly one chunk, so each claude writes its OWN chunk-results file
# (never a shared one, which concurrent incremental rewrites would clobber), and the heartbeat merges
# them into $RESULTS. The prompt is unchanged per chunk: only the two paths it names are swapped to that
# chunk's queue and results file. run_claude_on_chunk substitutes the full-queue and full-results paths
# (which $PROMPT was expanded against) for the chunk's own.
run_claude_on_chunk() {
  # $1 = chunk queue path, $2 = chunk results path, $3 = per-chunk log path
  local chunk_prompt
  chunk_prompt="${PROMPT//$QUEUE/$1}"
  chunk_prompt="${chunk_prompt//$RESULTS/$2}"
  "$CLAUDE" -p "$chunk_prompt" \
    --model "${OVERTURE_MODEL_EXTRACTION}" \
    --allowedTools "Read,Write,WebFetch" >> "$3" 2>&1
}

cd "$PROJECT_DIR"

# Wipe any chunk files from a previous run before splitting, so a bigger run's leftovers cannot be
# launched as this run's work (split_queue_into_chunks also clears its own chunk queues; this also
# clears stale chunk-results). Assume-it-runs-twice.
rm -rf "$CHUNKDIR" 2>/dev/null || true
mkdir -p "$CHUNKDIR" 2>/dev/null || true
# Per-chunk logs live directly in the support dir (not in CHUNKDIR), so wipe stale ones too: a bigger
# previous run leaves higher-numbered chunk logs a smaller run never truncates, and a stale chunk-6 log
# read as this run's would mislead.
rm -f "$SUPPORT"/scout-extract-run.chunk-*.log 2>/dev/null || true

CHUNK_COUNT="$(split_queue_into_chunks "$QUEUE" "$MAX_PARALLEL" "$CHUNKDIR")"

# #856: every exit status is CAPTURED, never allowed to kill the script. Under `set -e` a claude that
# died (a crash, an API error, an out-of-memory kill) would take the whole script down with it, before
# anything could write down what had been asked for and lost. With chunks, one dying process must not
# take the others (or the merge and the results guard) down either: each source in a dead chunk comes
# home as an honest not_read from the guard below, instead of the whole run vanishing.
CLAUDE_STATUS=0

if [ "${CHUNK_COUNT:-0}" -ge 1 ]; then
  # Launch one claude per chunk, concurrently, each writing its own chunk-results file and its own log.
  k=1
  while [ "$k" -le "$CHUNK_COUNT" ]; do
    CHUNK_LOG="$SUPPORT/scout-extract-run.chunk-$k.log"
    : > "$CHUNK_LOG"
    run_claude_on_chunk "$CHUNKDIR/chunk-queue-$k.json" "$CHUNKDIR/chunk-results-$k.json" "$CHUNK_LOG" &
    CHUNK_PIDS="$CHUNK_PIDS $!"
    k=$((k + 1))
  done
  # #1037: hand the chunk PIDs to the heartbeat (forked before this, so it cannot see CHUNK_PIDS), so a
  # cancel can stop exactly these processes and nothing else.
  printf '%s' "$CHUNK_PIDS" > "$CHUNK_PIDS_FILE"

  # Wait for every chunk, capturing each status so one failure is recorded without hiding the others.
  # The first non-zero becomes the run's status; the results guard below is the load-bearing check for
  # what actually came back, whatever the exit codes say. Written as an `if` (not `&&`) so a chunk that
  # exits non-zero cannot trip `set -e` and take the whole script down on the failure path.
  for pid in $CHUNK_PIDS; do
    st=0
    wait "$pid" || st=$?
    if [ "$st" != "0" ] && [ "$CLAUDE_STATUS" = "0" ]; then CLAUDE_STATUS="$st"; fi
  done
  CHUNK_PIDS=""   # all reaped; nothing left for the trap to kill

  # Fold each chunk's log tail into the main log, so the reason a chunk failed travels with the run
  # (the results guard reads the main log's tail into the not_read note).
  k=1
  while [ "$k" -le "$CHUNK_COUNT" ]; do
    CHUNK_LOG="$SUPPORT/scout-extract-run.chunk-$k.log"
    echo "--- chunk $k log tail ---"
    tail -n 4 "$CHUNK_LOG" 2>/dev/null || true
    k=$((k + 1))
  done

  # The final merge, now that every chunk has exited, so $RESULTS reflects the last writes each chunk
  # made between the previous heartbeat tick and finishing.
  merge_chunk_results "$QUEUE" "$CHUNKDIR" "$RESULTS"
else
  # Fallback for a node-free machine (split printed 0): run a single claude against the full queue,
  # writing $RESULTS directly, exactly as the sequential path always did.
  echo "scout-extract: not chunking (node unavailable or empty queue); running one process"
  "$CLAUDE" -p "$PROMPT" \
    --model "${OVERTURE_MODEL_EXTRACTION}" \
    --allowedTools "Read,Write,WebFetch" || CLAUDE_STATUS=$?
fi

# #1015: one last derive now that claude has exited, so the count reflects whatever landed between
# the previous heartbeat tick and the process actually finishing, rather than sitting stale.
update_progress_from_results "$QUEUE" "$RESULTS" "$PROGRESS"

# #856: whatever the model did or failed to do, every source this run was GIVEN now has a result. A
# source the run never came back with is written down as `not_read`, with the tail of this log, so a lost
# run reads as a reported failure instead of a silence. Runs before record_model so the stamp lands on
# the file the app will actually read.
ensure_every_queued_source_reported "$QUEUE" "$RESULTS" "$LOG" "$CLAUDE_STATUS"

# #804: stamp what actually wrote this, so a draft can be traced to the model behind it.
record_model "$RESULTS" "${OVERTURE_MODEL_EXTRACTION}"

# #1011: fail loud. A run that came back with no results for a source it was GIVEN has failed, however
# calmly claude exited, and claude exiting 0 while writing nothing is exactly what happened on
# 2026-07-16: the log said "finished (claude exit 0)" over a run that lost every show it extracted.
# The app does not read this status (it is launched detached), so this is for the log and for anyone,
# human or script, who runs this by hand: the one line that said success must stop saying it.
RUN_STATUS="$CLAUDE_STATUS"
if [ "${RESULTS_MISSING_SOURCES:-0}" = "1" ] && [ "${RUN_STATUS}" = "0" ]; then
  RUN_STATUS=9
fi

echo "scout-extract run finished (claude exit ${CLAUDE_STATUS}, run status ${RUN_STATUS}) -> $RESULTS"
exit "$RUN_STATUS"
