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
open_run_log "scout-extract-run.log"

# See lib/resolve-node.sh (#636): puts a real node on PATH before claude (and its hooks) launch.
. "$(dirname "$0")/lib/resolve-node.sh"

QUEUE="$SUPPORT/overture-scout-extract-queue.json"
RESULTS="$SUPPORT/overture-scout-extract-results.json"
PROGRESS="$SUPPORT/overture-scout-extract-progress.json"
RUNBOOK="$PROJECT_DIR/docs/scout-extract-runbook.md"
MARKER="$SUPPORT/scout-extract-running"

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
( while :; do
    sleep 60
    touch "$MARKER" 2>/dev/null || exit
    update_progress_from_results "$QUEUE" "$RESULTS" "$PROGRESS"
  done ) &
HEARTBEAT_PID=$!
trap 'kill "$HEARTBEAT_PID" 2>/dev/null; rm -f "$MARKER"' EXIT

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

# Headless Claude Code run. Read (the pinned pages), Write (results + progress), WebFetch (each event's
# detail page, for the venue and exact date, which the listings page usually lacks). No Bash, no Skill,
# no WebSearch: this run reads files, follows links it was given, and writes two files.
#
# #856: the exit status is CAPTURED, never allowed to kill the script. Under `set -e` a claude that died
# (a crash, an API error, an out-of-memory kill) took the whole script down with it, right here, before
# anything could write down what had been asked for and lost. The run vanished, and the app was left
# polling for a file that was never coming.
cd "$PROJECT_DIR"
CLAUDE_STATUS=0
"$CLAUDE" -p "$PROMPT" \
  --model "${OVERTURE_MODEL_EXTRACTION}" \
  --allowedTools "Read,Write,WebFetch" || CLAUDE_STATUS=$?

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
