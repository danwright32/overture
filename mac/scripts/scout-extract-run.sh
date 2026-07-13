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
( while :; do sleep 60; touch "$MARKER" 2>/dev/null || exit; done ) &
HEARTBEAT_PID=$!
trap 'kill "$HEARTBEAT_PID" 2>/dev/null; rm -f "$MARKER"' EXIT

# Seed the progress file so the app shows "0 of N" immediately rather than a bare spinner while the
# run boots (a cold Claude Code start is not instant). The run updates it as it goes.
TOTAL=$(grep -c '"sourceId"' "$QUEUE" 2>/dev/null || echo 0)
printf '{"version":1,"total":%s,"completed":0}\n' "$TOTAL" > "$PROGRESS"

PROMPT="You are the Overture scout-extract run (v1). Follow $RUNBOOK exactly. Read the work-list at
$QUEUE. TODAY'S DATE matters: only report performances that are today or later.

For EVERY item in the work-list:
  1. Read the pinned page at that item's pagePath. It is normalized HTML: scripts, styles and
     attribute noise are stripped, but the tag structure (INCLUDING TABLES AND CELLS) and links are
     intact. Some calendars print no dates at all and put each concert in a cell of a month grid, so
     the date is implied by WHICH cell it sits in and by the month heading. Read the grid.
  2. Extract every UPCOMING performance. Do NOT invent anything that is not on the page. A page whose
     listings are all in the past is a normal, healthy state (an organization between seasons); report
     it honestly rather than reaching for something to return.
  3. The listings page usually does NOT carry the venue, and sometimes not the year. Both are on each
     event's own detail page. FOLLOW the event's link (WebFetch) to get the venue and the exact date.
     Overture needs the venue: it drives classification and the pitch itself. Never guess a venue.
  4. Judge the PAGE and report exactly one verdict for it:
       upcoming_listings  it has upcoming performances (you are returning them)
       all_past           it has dated listings, but every one has already happened
       no_dated_content   it carries no dated listings at all (often the wrong page entirely)
       unreadable         the bytes carry no event data (e.g. a calendar drawn by JavaScript, or a
                          login wall). Say so; do not pretend to have read it.
  5. PAGINATION: a listings page often carries links to further pages (/P20, /P40, ?page=2). Read the
     FIRST page only, and say so in that source's note ("page 1 of N; later pages not read"). Do not
     follow them. It is a deliberate rule, not a gap: the app hashes the bytes of the page it fetched,
     so what lives beyond them is not part of the set it is reconciling against, and a run that wanders
     off across an unbounded number of pages is the one that never comes back.
  6. Update $PROGRESS after each item: {\"version\":1,\"total\":N,\"completed\":K}.

YOU MUST ALWAYS write $RESULTS BEFORE YOU FINISH. This run is DETACHED: nobody is reading your output
and nobody can answer you. A question is not an output. Never stop to ask which of two things to do:
decide, do it, and record the decision in that source's `note`. If you are unsure, a result with a
verdict and an honest note is worth everything, and a question is worth nothing, because the work is
thrown away and the app is left waiting for a file that never arrives. That has already happened once:
twenty correctly extracted shows were lost to a question about pagination.

Copy each item's sourceId VERBATIM into its result. Never rebuild it: a reconstructed id matches
nothing on the way home and the work vanishes silently.

Write the complete v1 ScoutExtractResults JSON to $RESULTS and nothing else to that file:
{\"version\":1,\"generatedAt\":\"<ISO8601>\",\"results\":[{\"sourceId\":\"...\",\"verdict\":\"...\",
\"events\":[{\"title\":\"...\",\"presenter\":\"...\",\"venue\":\"...\",\"performanceDate\":\"YYYY-MM-DD\",
\"sourceUrl\":\"...\"}],\"note\":\"one short line on anything that made this hard\"}]}"

resolve_claude

# Headless Claude Code run. Read (the pinned pages), Write (results + progress), WebFetch (each event's
# detail page, for the venue and exact date, which the listings page usually lacks). No Bash, no Skill,
# no WebSearch: this run reads files, follows links it was given, and writes two files.
cd "$PROJECT_DIR"
"$CLAUDE" -p "$PROMPT" \
  --model "${OVERTURE_MODEL_EXTRACTION}" \
  --allowedTools "Read,Write,WebFetch"

# #804: stamp what actually wrote this, so a draft can be traced to the model behind it.
record_model "$RESULTS" "${OVERTURE_MODEL_EXTRACTION}"

echo "scout-extract run finished -> $RESULTS"
