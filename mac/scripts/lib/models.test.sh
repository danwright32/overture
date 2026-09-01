#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"

# Two cases below run record_model and record_run_cost with PATH pointing at a directory that holds
# nothing, to prove a detached run still succeeds when there is no node to stamp it with. Bash writes
# "node: command not found" while that happens, which is the same thing it writes for a mistyped
# assertion, so this declares the absence is the thing being rehearsed (#2501). It names only node:
# any other unresolved command in this fixture still fails the run.
echo "shell-fixture-expects-missing-command: node"

# #804: every detached run used to invoke `claude -p` with no --model flag, so it silently inherited
# whatever the CLI default happened to be on Dan's machine that day.
#
# For the mechanical runs that was only money. For DRAFTING it was his voice: the words that reach a
# stranger. A CLI upgrade or a settings change could have altered how every email he sends sounds, with
# no code change, no commit, and no warning, and nothing in the repo recorded which model wrote a draft,
# so he would only have found out by noticing the emails reading differently.
#
# The model choice lives in ONE file so it cannot be got right in two scripts and wrong in the third.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

assert_equals() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected to contain: ${needle}"
    echo "  in: ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/models.sh"

# Drafting: Dan's call (2026-07-12). The TIER is pinned, not the exact version, so he picks up each new
# Opus as it ships. He accepted that his voice can shift with a new model in exchange for the
# improvement, which is only a reasonable trade because the model used is now RECORDED: he can tell what
# wrote a draft rather than sensing that something changed.
assert_equals "drafting uses the strong tier" "opus" "${OVERTURE_MODEL_DRAFTING}"

# The extraction run. It LOOKED like the cheap-model case (a strict output schema, no judgment), and rode
# on haiku on that reasoning. Dan's call (2026-07-17), after the first real watchlist scouts: haiku does
# not actually do the job. On a 19-source queue it read only the first ~6 pages and then fabricated
# "no dated content" for the rest without opening them, and it made ZERO detail-page fetches all run, so
# even the pages it did read produced venue-less events that get rejected before ingest. Reading a
# calendar is not mechanical after all: it needs the stamina to work a whole queue and follow each event
# to its own page. The extraction run only ever fires on a scout Dan STARTS (the daily automatic run
# watches and spends nothing, ScoutService.swift), so this heavier tier costs usage only on his manual
# scouts, never on autopilot.
assert_equals "reading a calendar needs a model that will actually read it" "sonnet" "${OVERTURE_MODEL_EXTRACTION}"

# #874: the reply run is NAMED for the classification half of its job, and that is what hid this. It also
# DRAFTS the reply, in Dan's voice, to a person who has already written back to him: a warmer lead than
# any cold pitch, and by this file's own definition that is drafting, not a mechanical read. It ran on the
# cheap tier for exactly as long as nobody said the second half of its name out loud.
#
# Asserted against the DRAFTING tier rather than the literal "opus", so the reply drafter follows Dan
# wherever he pins drafting next instead of quietly falling behind it a second time.
assert_equals "a reply to a warm lead is DRAFTING, so it uses the drafting tier" \
  "${OVERTURE_MODEL_DRAFTING}" "${OVERTURE_MODEL_REPLY_CLASSIFY}"

# The whole point: nothing that writes words to a stranger may quietly become the cheap model, and the
# mechanical run must not quietly become the expensive one.
for var in OVERTURE_MODEL_DRAFTING OVERTURE_MODEL_REPLY_CLASSIFY; do
  if [[ "${!var}" == "${OVERTURE_MODEL_EXTRACTION}" ]]; then
    echo "FAIL - ${var} must not share the extraction model: one is Dan's voice, the other is a parser"
    FAILURES=$((FAILURES + 1))
  else
    echo "ok - ${var} is deliberately not the mechanical model"
  fi
done

# Every runner actually PASSES it. A model constant nobody references is worse than none: it reads as
# solved while every run still inherits the CLI default.
for script in prep-run.sh reply-classify-run.sh scout-extract-run.sh; do
  body="$(cat "${SCRIPT_DIR}/../${script}")"
  assert_contains "${script} passes --model" "${body}" '--model'
  assert_contains "${script} sources the shared model list" "${body}" 'lib/models.sh'
done

# And each records what it used, so a draft can be traced to what wrote it. Without this, pinning the
# TIER still lets the voice change under Dan with no way to confirm it did.
for script in prep-run.sh reply-classify-run.sh scout-extract-run.sh; do
  body="$(cat "${SCRIPT_DIR}/../${script}")"
  assert_contains "${script} records the model it used" "${body}" 'record_model'
done

# --- record_model, actually executed ---------------------------------------------------------------
#
# The greps above prove the runners CALL it. These prove it does the right thing, including on the paths
# that matter most: a run that produced nothing, a run whose output is garbage, and a machine with no
# node. record_model runs at the very end of a detached run, so anything it does wrong lands on Dan as a
# corrupted results file or a run that dies after doing all its real work.

# One trap naming every scratch this fixture makes (#3249). It used to be one trap per directory, and
# bash keeps exactly ONE EXIT trap, so the later one silently replaced this one and the first directory
# was left behind on every run. Invisible until #3249 gave the runner's leak check sight of scratches
# made this way. WEBTMP and FIXTMP are declared here, empty, so this trap can name them under `set -u`
# before the lines that fill them are reached.
TMP="$(fixture_scratch_dir)"
WEBTMP=""
FIXTMP=""
trap 'rm -rf "${TMP}" "${WEBTMP:-}" "${FIXTMP:-}"' EXIT

# The happy path: the model is stamped in, and nothing else is disturbed.
printf '%s' '{"version":2,"generatedAt":"2026-07-12T00:00:00Z","results":[{"naturalKey":"show"}]}' \
  > "${TMP}/results.json"
record_model "${TMP}/results.json" "opus"
stamped="$(node -e 'const j=require(process.argv[1]); console.log(j.model)' "${TMP}/results.json" 2>/dev/null)"
kept="$(node -e 'const j=require(process.argv[1]); console.log(j.results[0].naturalKey)' "${TMP}/results.json" 2>/dev/null)"
assert_equals "the model is stamped into the results file" "opus" "${stamped}"
assert_equals "and the run's actual results are left untouched" "show" "${kept}"

# A run that produced NO results file. Common (a run that failed, or found nothing to do) and already
# reported loudly on its own path, so this must exit quietly rather than fail the run after the fact.
if record_model "${TMP}/does-not-exist.json" "opus"; then
  echo "ok - a missing results file is not an error here (it is reported on its own path)"
else
  echo "FAIL - record_model must not fail a run just because there was nothing to stamp"
  FAILURES=$((FAILURES + 1))
fi

# A results file that is NOT valid JSON. That means the run itself failed, which is reported elsewhere.
# The file must be left EXACTLY as it was: overwriting it would destroy the evidence of what went wrong,
# and turning it into a second failure would only confuse the first.
printf '%s' 'this is not json {' > "${TMP}/garbage.json"
before="$(cat "${TMP}/garbage.json")"
record_model "${TMP}/garbage.json" "opus" || true
after="$(cat "${TMP}/garbage.json")"
assert_equals "an unparsable results file is left exactly as it was" "${before}" "${after}"

# No node on PATH. The stamp is a nice-to-have; the run's actual results are not. Losing the trace must
# never lose Dan's drafts.
printf '%s' '{"version":2,"results":[]}' > "${TMP}/nonode.json"
nonode_before="$(cat "${TMP}/nonode.json")"
if PATH="/nonexistent" record_model "${TMP}/nonode.json" "opus"; then
  echo "ok - no node on PATH degrades to no trace, never to a failed run"
else
  echo "FAIL - record_model must not fail the run when node is unavailable"
  FAILURES=$((FAILURES + 1))
fi
assert_equals "and the results file survives a machine with no node" \
  "${nonode_before}" "$(cat "${TMP}/nonode.json")"

# --- record_run_cost (#1593, milestone 32 Phase 0.1) -------------------------------------------------
#
# Dan asked to see what a reachability check actually costs before deciding how many nights he can select
# at once. The number comes from the final `result` envelope claude emits under --output-format
# stream-json. The failure path is the one that matters: an event file that is missing, truncated, or
# unparseable must say so, because a silent 0.00 would read as "that was free" and he would size a
# 66-show batch against a number that was never measured.

printf '%s' '{"version":2,"results":[]}' > "${TMP}/cost-ok.json"
{
  printf '%s\n' '{"type":"system","subtype":"init"}'
  printf '%s\n' '{"type":"assistant","message":{"content":"working"}}'
  printf '%s\n' '{"type":"result","subtype":"success","total_cost_usd":1.2345,"duration_ms":241000}'
} > "${TMP}/events-ok.jsonl"
record_run_cost "${TMP}/cost-ok.json" "${TMP}/events-ok.jsonl"
assert_contains "a complete event stream records the dollar cost" \
  "$(cat "${TMP}/cost-ok.json")" '"usd": 1.2345'
assert_contains "and records the duration" \
  "$(cat "${TMP}/cost-ok.json")" '"durationMs": 241000'
assert_contains "and marks the reading as recorded" \
  "$(cat "${TMP}/cost-ok.json")" '"recorded": true'

# #2762: and whether the run had the machine to itself, which is what makes this wall clock comparable
# with the next run's. The app refuses to pool a contended sample with a solo one, so this flag is what
# tells the two apart, and it is written on EVERY complete reading rather than only when contended: an
# absent flag means "a runner that predates this", which the app treats as unpoolable, and a solo run
# reporting nothing would silently stop teaching the estimate anything.
printf '%s' '{"version":2,"results":[]}' > "${TMP}/cost-solo.json"
OVERTURE_RUN_CONTENDED=0 record_run_cost "${TMP}/cost-solo.json" "${TMP}/events-ok.jsonl"
assert_contains "a run with the machine to itself says so" \
  "$(cat "${TMP}/cost-solo.json")" '"contended": false'

printf '%s' '{"version":2,"results":[]}' > "${TMP}/cost-shared.json"
OVERTURE_RUN_CONTENDED=1 record_run_cost "${TMP}/cost-shared.json" "${TMP}/events-ok.jsonl"
assert_contains "a run that shared the machine says so" \
  "$(cat "${TMP}/cost-shared.json")" '"contended": true'

# A caller that said nothing writes NO flag, rather than claiming solo. This is the update window: the
# runner script is resolved out of the git checkout and update-overture.sh fast-forwards it before the
# rebuild, so a new app meets an old script, and an old script claiming "solo" would file exactly the
# co-run this exists to measure as evidence about a run that had the machine to itself.
printf '%s' '{"version":2,"results":[]}' > "${TMP}/cost-unsaid.json"
(unset OVERTURE_RUN_CONTENDED; record_run_cost "${TMP}/cost-unsaid.json" "${TMP}/events-ok.jsonl")
assert_not_contains "a caller that said nothing claims nothing" \
  "$(cat "${TMP}/cost-unsaid.json")" '"contended"'

# #3004: the results file says what KIND of run wrote it, and which slot it ran in.
#
# A finished results file recorded version, generatedAt and results, and nothing about its own provenance,
# so a check's file and a Prep run's file were indistinguishable once written. That is the fact #2762's
# session 1 got wrong, and the only thing that caught it was a person reading prep-run.log by eye. The
# runner HOLDS the fact when it writes the file (OVERTURE_RUN_SLOT since #2980), so it records it.
#
# At the TOP LEVEL, not inside runCost: it is true of the file whether or not the cost reading completed,
# and a fact filed under a key that can be absent is a fact that disappears exactly when the run went
# wrong.
printf '%s' '{"version":2,"results":[]}' > "${TMP}/kind-check.json"
OVERTURE_RUN_CONTENDED=0 OVERTURE_RUN_KIND=check OVERTURE_RUN_SLOT=check \
  record_run_cost "${TMP}/kind-check.json" "${TMP}/events-ok.jsonl"
assert_contains "a check says it was a check" \
  "$(cat "${TMP}/kind-check.json")" '"runKind": "check"'
assert_contains "and which slot it ran in" \
  "$(cat "${TMP}/kind-check.json")" '"runSlot": "check"'

printf '%s' '{"version":2,"results":[]}' > "${TMP}/kind-prep.json"
OVERTURE_RUN_CONTENDED=0 OVERTURE_RUN_KIND=prep OVERTURE_RUN_SLOT=prep \
  record_run_cost "${TMP}/kind-prep.json" "${TMP}/events-ok.jsonl"
assert_contains "a prep run says it was a prep run" \
  "$(cat "${TMP}/kind-prep.json")" '"runKind": "prep"'

# A check running in the PREP slot is the case the stamp exists for: the two facts differ, and both are
# recorded, so the file cannot be read as evidence about the slot it happens to sit in.
printf '%s' '{"version":2,"results":[]}' > "${TMP}/kind-crossed.json"
OVERTURE_RUN_CONTENDED=0 OVERTURE_RUN_KIND=check OVERTURE_RUN_SLOT=prep \
  record_run_cost "${TMP}/kind-crossed.json" "${TMP}/events-ok.jsonl"
assert_contains "a check sitting in the prep slot still says it is a check" \
  "$(cat "${TMP}/kind-crossed.json")" '"runKind": "check"'
assert_contains "and does not hide which slot that was" \
  "$(cat "${TMP}/kind-crossed.json")" '"runSlot": "prep"'

# Said nothing, claims nothing: the same update-window rule as `contended` above, and for the same reason.
# An old script meeting a new app must not be read as a Prep run just because that is the commoner kind.
printf '%s' '{"version":2,"results":[]}' > "${TMP}/kind-unsaid.json"
(unset OVERTURE_RUN_KIND; unset OVERTURE_RUN_SLOT; \
  OVERTURE_RUN_CONTENDED=0 record_run_cost "${TMP}/kind-unsaid.json" "${TMP}/events-ok.jsonl")
assert_not_contains "a caller that said nothing claims no kind" \
  "$(cat "${TMP}/kind-unsaid.json")" '"runKind"'
assert_not_contains "and no slot" \
  "$(cat "${TMP}/kind-unsaid.json")" '"runSlot"'

# A value nobody recognises is not written either. The reader refuses an unknown kind, and writing one
# would turn an environment typo into a permanent refusal nobody can see the cause of.
printf '%s' '{"version":2,"results":[]}' > "${TMP}/kind-nonsense.json"
OVERTURE_RUN_CONTENDED=0 OVERTURE_RUN_KIND=banana OVERTURE_RUN_SLOT=banana \
  record_run_cost "${TMP}/kind-nonsense.json" "${TMP}/events-ok.jsonl"
assert_not_contains "an unrecognised kind is not recorded" \
  "$(cat "${TMP}/kind-nonsense.json")" '"runKind"'

# The stamp survives the INCOMPLETE cost path, which is the whole reason it sits outside runCost.
printf '%s' '{"version":2,"results":[]}' > "${TMP}/kind-incomplete.json"
OVERTURE_RUN_KIND=check OVERTURE_RUN_SLOT=check \
  record_run_cost "${TMP}/kind-incomplete.json" "${TMP}/no-such-events.jsonl"
assert_contains "a run whose cost could not be read still says what it was" \
  "$(cat "${TMP}/kind-incomplete.json")" '"runKind": "check"'
assert_contains "the cost reading itself is still reported as not recorded" \
  "$(cat "${TMP}/kind-incomplete.json")" '"recorded": false'

# Failure path one: the event file never appeared, because claude died before writing anything.
printf '%s' '{"version":2,"results":[]}' > "${TMP}/cost-missing.json"
record_run_cost "${TMP}/cost-missing.json" "${TMP}/no-such-events.jsonl"
assert_contains "a missing event file is recorded as NOT recorded, never as zero" \
  "$(cat "${TMP}/cost-missing.json")" '"recorded": false'
if [[ "$(cat "${TMP}/cost-missing.json")" == *'"usd"'* ]]; then
  echo "FAIL - a missing event file must not write a usd figure at all"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - and writes no usd figure that could be read as free"
fi

# Failure path two: the run was killed mid-write, so the last line is half a JSON object and there is no
# result envelope. This is what a cancel or a crash actually leaves behind.
printf '%s' '{"version":2,"results":[]}' > "${TMP}/cost-truncated.json"
{
  printf '%s\n' '{"type":"system","subtype":"init"}'
  printf '%s' '{"type":"result","subtype":"success","total_cost_'
} > "${TMP}/events-truncated.jsonl"
record_run_cost "${TMP}/cost-truncated.json" "${TMP}/events-truncated.jsonl"
assert_contains "a truncated event stream is recorded as NOT recorded" \
  "$(cat "${TMP}/cost-truncated.json")" '"recorded": false'

# Failure path three: a well-formed stream that simply never reached a result envelope.
printf '%s' '{"version":2,"results":[]}' > "${TMP}/cost-noresult.json"
printf '%s\n' '{"type":"assistant","message":{"content":"still going"}}' > "${TMP}/events-noresult.jsonl"
record_run_cost "${TMP}/cost-noresult.json" "${TMP}/events-noresult.jsonl"
assert_contains "an event stream with no result envelope is recorded as NOT recorded" \
  "$(cat "${TMP}/cost-noresult.json")" '"recorded": false'

# The same rule record_model already follows: an unparsable RESULTS file is evidence of a failed run and
# must be left exactly as it was.
printf '%s' 'this is not json {' > "${TMP}/cost-garbage.json"
cost_before="$(cat "${TMP}/cost-garbage.json")"
record_run_cost "${TMP}/cost-garbage.json" "${TMP}/events-ok.jsonl" || true
assert_equals "an unparsable results file is left exactly as it was" \
  "${cost_before}" "$(cat "${TMP}/cost-garbage.json")"

# And no node means no stamp, never a failed run.
printf '%s' '{"version":2,"results":[]}' > "${TMP}/cost-nonode.json"
if PATH="/nonexistent" record_run_cost "${TMP}/cost-nonode.json" "${TMP}/events-ok.jsonl"; then
  echo "ok - no node on PATH degrades to no cost trace, never to a failed run"
else
  echo "FAIL - record_run_cost must not fail the run when node is unavailable"
  FAILURES=$((FAILURES + 1))
fi

# #1597: a chunked run is up to 10 concurrent claudes, so the cost arrives as several event streams and
# the total is their SUM. Getting this wrong is not a cosmetic reporting bug: Dan sizes the batch ceiling
# from this figure, so reading only one stream of four would tell him a week costs a quarter of what it
# does, and the brake would let through four times the spend he agreed to.
printf '%s' '{"version":6,"results":[]}' > "${TMP}/cost-chunked.json"
printf '%s\n' '{"type":"result","subtype":"success","total_cost_usd":1.50,"duration_ms":100000}' \
  > "${TMP}/events-chunk-1.jsonl"
printf '%s\n' '{"type":"result","subtype":"success","total_cost_usd":2.25,"duration_ms":240000}' \
  > "${TMP}/events-chunk-2.jsonl"
record_run_cost "${TMP}/cost-chunked.json" "${TMP}/events-chunk-1.jsonl" "${TMP}/events-chunk-2.jsonl"
assert_contains "a chunked run sums the cost of every stream" \
  "$(cat "${TMP}/cost-chunked.json")" '"usd": 3.75'
# Chunks run CONCURRENTLY, so the run's wall clock is the longest chunk, never the sum. Adding them
# would claim a 4-minute run took 5m40s, making the parallel path look like the slow thing it replaced.
assert_contains "the duration is the longest stream, not the sum, because chunks overlap" \
  "$(cat "${TMP}/cost-chunked.json")" '"durationMs": 240000'
assert_contains "a complete chunked reading is marked recorded" \
  "$(cat "${TMP}/cost-chunked.json")" '"recorded": true'

# THE FAILURE THAT MATTERS. One chunk died and left no envelope. The surviving chunks' cost is real, but
# it is NOT the run's cost, and presenting it as the total is exactly how a brake gets sized too loose.
printf '%s' '{"version":6,"results":[]}' > "${TMP}/cost-partial.json"
record_run_cost "${TMP}/cost-partial.json" "${TMP}/events-chunk-1.jsonl" "${TMP}/no-such-chunk.jsonl"
assert_contains "a run where one chunk reported nothing is NOT marked recorded" \
  "$(cat "${TMP}/cost-partial.json")" '"recorded": false'
if [[ "$(cat "${TMP}/cost-partial.json")" == *'"usd":'* ]]; then
  echo "FAIL - a partial reading must not present itself as the run's usd cost"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - a partial reading writes no usd figure that could be mistaken for the total"
fi
assert_contains "a partial reading still says how much it DID see, under its own name" \
  "$(cat "${TMP}/cost-partial.json")" '"partialUsd": 1.5'
assert_contains "and says how many streams reported" \
  "$(cat "${TMP}/cost-partial.json")" '"streamsRecorded": 1'
assert_contains "out of how many there were" \
  "$(cat "${TMP}/cost-partial.json")" '"streams": 2'

# The single-stream call is unchanged, so every existing caller keeps working untouched.
printf '%s' '{"version":6,"results":[]}' > "${TMP}/cost-single.json"
record_run_cost "${TMP}/cost-single.json" "${TMP}/events-chunk-2.jsonl"
assert_contains "a single-stream run still records its cost exactly as before" \
  "$(cat "${TMP}/cost-single.json")" '"usd": 2.25'
assert_contains "and is still marked recorded" \
  "$(cat "${TMP}/cost-single.json")" '"recorded": true'


# --- tee_run_events (#1593, milestone 32 Phase 0.1) --------------------------------------------------
#
# Capturing the cost means asking claude for --output-format stream-json, whose raw JSON is unreadable.
# The run log is the ONLY human trace of a run that takes minutes, and the project rule is that working,
# still-alive and failed must stay visibly distinct. So the raw stream goes to its own file for parsing
# while a readable trickle keeps flowing to the log. Losing that trickle would silently remove the
# still-alive signal, which is why it is asserted here and not left to a careful reading of the diff.

{
  printf '%s\n' '{"type":"system","subtype":"init","model":"opus"}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Looking up contacts"}]}}'
  printf '%s\n' '{"type":"result","subtype":"success","total_cost_usd":0.42,"duration_ms":1000}'
} > "${TMP}/stream-in.jsonl"

trickle="$(tee_run_events "${TMP}/stream-out.jsonl" < "${TMP}/stream-in.jsonl")"

assert_equals "every raw event line is captured verbatim for parsing" \
  "$(cat "${TMP}/stream-in.jsonl")" "$(cat "${TMP}/stream-out.jsonl")"

if [[ -n "${trickle}" ]]; then
  echo "ok - the run log still receives a still-alive trickle"
else
  echo "FAIL - tee_run_events emitted nothing, so a long run would look dead in the log"
  FAILURES=$((FAILURES + 1))
fi

if [[ "${trickle}" == *'{"type":"assistant"'* ]]; then
  echo "FAIL - the trickle is raw JSON, which is not a human-readable progress signal"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - and the trickle is not raw JSON"
fi

# A stream that is not JSON at all (claude failed and printed an error) must still reach the log rather
# than being swallowed by a parser that only understands events.
printf '%s\n' 'error: could not reach the API' > "${TMP}/stream-bad.jsonl"
bad_trickle="$(tee_run_events "${TMP}/stream-bad-out.jsonl" < "${TMP}/stream-bad.jsonl")"
assert_contains "a non-JSON line still reaches the log instead of vanishing" \
  "${bad_trickle}" "could not reach the API"

# --- #1721: counting the run's REAL web calls -----------------------------------------------------------
#
# The runbook states a hop cap. A cap that lives only in a prompt is a hope (L27), and until now nothing
# read the event stream the runner has written since #1593, so the cap was never once checked.
#
# What counts is every ROUTE to the web, not just WebFetch, and that is measured rather than assumed:
# in Dan's real 2026-07-28 run, chunk 3 reached the web with mcp__playwright__browser_navigate, and the
# prep scope deliberately allows Bash, so curl is a route too. A counter blind to those reports a small
# number for a run that made many calls, which is the same false comfort as no counter at all.
WEBTMP="$(fixture_scratch_dir)"

# One stream carrying every route, in the real stream-json shape: tool_use blocks inside an assistant
# message's content array.
cat > "${WEBTMP}/events.jsonl" <<'EOF'
{"type":"system","subtype":"init"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebFetch","input":{"url":"https://a.example"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebSearch","input":{"query":"x"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__playwright__browser_navigate","input":{"url":"https://b.example"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"curl -s https://c.example"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls /tmp"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/x"}}]}}
{"type":"result","total_cost_usd":0.5,"duration_ms":1000}
EOF

echo '{"version":6,"results":[{"naturalKey":"a"},{"naturalKey":"b"}]}' > "${WEBTMP}/results.json"
record_web_calls "${WEBTMP}/results.json" 4 "${WEBTMP}/events.jsonl"
web="$(cat "${WEBTMP}/results.json")"

# Four web calls: WebFetch, WebSearch, the browser navigation and the curl. The plain `ls` and the Read
# are not web calls and must not inflate the number Dan is judged against.
assert_contains "counts every route to the web, not just WebFetch" "${web}" '"total": 4'
assert_contains "a non-network Bash command is not counted as a web call" "${web}" '"bash": 1'
assert_contains "names the browser route it found" "${web}" '"browser": 1'
assert_contains "records the count as real when every stream reported" "${web}" '"recorded": true'

# The cap is per ITEM, so a run covering more shows is allowed proportionally more calls. Two items at a
# cap of 4 is a ceiling of 8, and four calls is comfortably under it.
assert_contains "judges the total against the cap scaled by how many shows the run covered" \
  "${web}" '"overCap": false'

# Over the cap: same stream, but a run that covered only ONE show has half the allowance.
echo '{"version":6,"results":[{"naturalKey":"a"}]}' > "${WEBTMP}/results-one.json"
record_web_calls "${WEBTMP}/results-one.json" 3 "${WEBTMP}/events.jsonl"
over="$(cat "${WEBTMP}/results-one.json")"
assert_contains "flags a run that went over its allowance" "${over}" '"overCap": true'

# An unreadable stream must never be quietly scored as zero calls. Same rule record_run_cost already
# follows for money: a partial figure presented as the real one is worse than no figure, because the
# number looks perfectly plausible and nothing says it is short.
echo '{"version":6,"results":[{"naturalKey":"a"}]}' > "${WEBTMP}/results-missing.json"
record_web_calls "${WEBTMP}/results-missing.json" 3 "${WEBTMP}/events.jsonl" "${WEBTMP}/nope.jsonl"
missing="$(cat "${WEBTMP}/results-missing.json")"
assert_contains "a stream that did not report is recorded as incomplete" "${missing}" '"recorded": false'
if [[ "${missing}" == *'"total":'* ]]; then
  echo "FAIL - an incomplete count still published a 'total' that downstream would read as the real one"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - and publishes no 'total' at all, so nothing can read a partial count as the real one"
fi

# --- #1864: a whole bill of performers is not one lookup --------------------------------------------
#
# The allowance was a flat number per SHOW, sized when one show meant researching one party. Since #1817
# an organiser-less show pursues every performer the listing names, and the runbook is explicit that
# there is NO headcount ceiling on that route, so the rooms this was built to watch (a cabaret room
# booking five-handers) blow an allowance built for one target. The runs that trip it first are the
# CORRECT ones, which is how a counter stops meaning anything precisely on the shows it was added for
# (L36).
#
# So the allowance counts research TARGETS. A performer named on the listing is surfaced as her own
# contact entry even when nothing was found for her (the runbook requires it, at low confidence), so the
# entries are the evidence of how many parties the item actually asked for.
echo '{"version":6,"results":[
  {"naturalKey":"a","contacts":[
    {"provenance":"performer","name":"One"},{"provenance":"performer","name":"Two"},
    {"provenance":"performer","name":"Three"},{"provenance":"performer","name":"Four"},
    {"provenance":"performer","name":"Five"}]}]}' > "${WEBTMP}/results-bill.json"
record_web_calls "${WEBTMP}/results-bill.json" 3 "${WEBTMP}/events.jsonl"
bill="$(cat "${WEBTMP}/results-bill.json")"
assert_contains "a five-hander is allowed five targets' worth of lookups, not one show's" \
  "${bill}" '"allowance": 15'
assert_contains "and says how many parties that allowance was sized for" "${bill}" '"parties": 5'
assert_contains "so four calls across a five-hander is not reported as overspending" \
  "${bill}" '"overCap": false'
assert_contains "while still reporting the show count it covered" "${bill}" '"items": 1'

# The ordinary show is untouched: one party, one show, the allowance it always had. Without this the
# fix would quietly raise the ceiling on every run and the counter would stop catching anything.
echo '{"version":6,"results":[{"naturalKey":"a","contacts":[{"provenance":"act","name":"An Act"}]}]}' \
  > "${WEBTMP}/results-plain.json"
record_web_calls "${WEBTMP}/results-plain.json" 3 "${WEBTMP}/events.jsonl"
plain="$(cat "${WEBTMP}/results-plain.json")"
assert_contains "a single-target show keeps exactly the allowance it always had" \
  "${plain}" '"allowance": 3'
assert_contains "and counts as one party" "${plain}" '"parties": 1'
assert_contains "so it is still flagged when it goes over" "${plain}" '"overCap": true'

# An item that reported no contacts at all still asked for one party. It must never be sized at zero,
# which would give the whole run an allowance of nothing and flag every run that found nobody.
echo '{"version":6,"results":[{"naturalKey":"a"},{"naturalKey":"b"}]}' > "${WEBTMP}/results-empty.json"
record_web_calls "${WEBTMP}/results-empty.json" 3 "${WEBTMP}/events.jsonl"
empty="$(cat "${WEBTMP}/results-empty.json")"
assert_contains "an item that found nobody is still one party, never zero" "${empty}" '"parties": 2'
assert_contains "so a run that found nothing is judged against a real allowance" \
  "${empty}" '"allowance": 6'

# An unparsable results file is the run having failed, reported on its own path. Overwriting it would
# destroy the evidence, exactly as record_run_cost refuses to.
printf '%s' 'not json{' > "${WEBTMP}/broken.json"
record_web_calls "${WEBTMP}/broken.json" 3 "${WEBTMP}/events.jsonl"
assert_equals "an unparsable results file is left exactly as it was" \
  'not json{' "$(cat "${WEBTMP}/broken.json")"

# --- #1835: a REFUSED call is not a call the run made -----------------------------------------------
#
# The counter read tool_use blocks and stopped there, so a call the permission layer refused was
# indistinguishable from one that fetched a page. Dan's 2026-07-30 run recorded `browser: 1` for a
# navigation that never happened, and the first diagnosis of #1824 then took that 1 as evidence the run
# HAD browser access. A count that inflates makes a run read as closer to its allowance than it is, and
# the allowance is the only thing watching a hop cap that otherwise lives in a prompt (L27).
#
# The events below are copied VERBATIM from a real refusal in
# `~/Library/Application Support/Overture-Debug/Overture/prep-run-events.chunk-1.jsonl` (2026-07-27,
# lines 60 and 61), not shaped so the rule under test fires (L48). Both of that run's refusals had the
# same two marks, and they are the two the detection uses:
#
#   `tool_result_meta: [{ id, non_execution_kind: "user-rejected" }]` on the user event, and
#   a tool_result whose text is "Claude requested permissions to use <tool>, but you haven't granted it yet."
#
# Measured across every prep event stream on this Mac (4 runs, 255 tool calls): 6 tool_results carried
# `is_error`, and only the 2 refusals carried `tool_result_meta`. The other 4 were calls that really ran
# and failed (a DNS miss, a curl that got a 302, two Bash exits). So `is_error` is NOT the mark of a
# refusal, and a counter that used it would drop real web calls, which is the failure this counter exists
# to prevent.
cat > "${WEBTMP}/denied.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_ok1","name":"WebFetch","input":{"url":"https://a.example"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"Fetched a.example","tool_use_id":"toolu_ok1"}]}}
{"type":"assistant","message":{"model":"claude-opus-5","id":"msg_011CdSyqvakWhmzkhc2qCZKJ","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01WtKpJp59k4RBTLGUQrcWm6","name":"mcp__playwright__browser_navigate","input":{"url":"https://www.carnegiehall.org/calendar/2026/08/01/manhattan-international-music-competition-winners-gala-concert-0730pm"},"caller":{"type":"direct"}}],"stop_reason":null,"usage":{"output_tokens":59}},"parent_tool_use_id":null,"session_id":"72af46f2-08a6-412f-b214-665274174501","uuid":"ad80537d-d230-4b9f-b43d-5fc782a7ff06","timestamp":"2026-07-27T17:46:49.465Z","tool_use_meta":[{"id":"toolu_01WtKpJp59k4RBTLGUQrcWm6","display_name":"Navigate to a URL","server_display_name":"Playwright"}]}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"Claude requested permissions to use mcp__playwright__browser_navigate, but you haven't granted it yet.","is_error":true,"tool_use_id":"toolu_01WtKpJp59k4RBTLGUQrcWm6"}]},"parent_tool_use_id":null,"session_id":"72af46f2-08a6-412f-b214-665274174501","uuid":"8dd97996-7c6d-4ac1-84b7-0d2cb991b47c","timestamp":"2026-07-27T17:46:49.469Z","tool_use_result":"Error: Claude requested permissions to use mcp__playwright__browser_navigate, but you haven't granted it yet.","tool_result_meta":[{"id":"toolu_01WtKpJp59k4RBTLGUQrcWm6","non_execution_kind":"user-rejected"}]}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_dns","name":"WebFetch","input":{"url":"https://www.evanoblezada.com"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"getaddrinfo ENOTFOUND www.evanoblezada.com","is_error":true,"tool_use_id":"toolu_dns"}]},"parent_tool_use_id":null,"session_id":"533d1eff-2abc-4971-bf07-b6a9a51aa249","uuid":"66e6b565-6423-496f-a775-c74937f9f954","timestamp":"2026-08-04T02:13:00.781Z","tool_use_result":"Error: getaddrinfo ENOTFOUND www.evanoblezada.com"}
{"type":"result","total_cost_usd":0.5,"duration_ms":1000}
EOF

echo '{"version":6,"results":[{"naturalKey":"a"}]}' > "${WEBTMP}/results-denied.json"
record_web_calls "${WEBTMP}/results-denied.json" 5 "${WEBTMP}/denied.jsonl"
denied="$(cat "${WEBTMP}/results-denied.json")"

assert_contains "a refused call is left out of the total the run is judged on" "${denied}" '"total": 2'
assert_contains "and the route it was refused on reports nothing reached" "${denied}" '"browser": 0'
assert_contains "a call that ran and failed on DNS still counts as one the run made" \
  "${denied}" '"fetch": 2'
assert_contains "the refusals are counted in their own right, not thrown away" "${denied}" '"denied": 1'
assert_contains "and named by the route the run was refused on" "${denied}" '"deniedByRoute"'

# Only refusals. The run reached the web zero times, and a counter that still said 3 would be reporting
# a capability the run does not have, which is exactly how #1824 was first misdiagnosed.
cat > "${WEBTMP}/all-denied.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_d1","name":"mcp__playwright__browser_navigate","input":{"url":"https://a.example"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"Claude requested permissions to use mcp__playwright__browser_navigate, but you haven't granted it yet.","is_error":true,"tool_use_id":"toolu_d1"}]},"tool_result_meta":[{"id":"toolu_d1","non_execution_kind":"user-rejected"}]}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_d2","name":"mcp__playwright__browser_navigate","input":{"url":"https://b.example"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"Claude requested permissions to use mcp__playwright__browser_navigate, but you haven't granted it yet.","is_error":true,"tool_use_id":"toolu_d2"}]},"tool_result_meta":[{"id":"toolu_d2","non_execution_kind":"user-rejected"}]}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_d3","name":"mcp__playwright__browser_navigate","input":{"url":"https://c.example"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"Claude requested permissions to use mcp__playwright__browser_navigate, but you haven't granted it yet.","is_error":true,"tool_use_id":"toolu_d3"}]},"tool_result_meta":[{"id":"toolu_d3","non_execution_kind":"user-rejected"}]}
{"type":"result","total_cost_usd":0.1,"duration_ms":100}
EOF
echo '{"version":6,"results":[{"naturalKey":"a"}]}' > "${WEBTMP}/results-all-denied.json"
record_web_calls "${WEBTMP}/results-all-denied.json" 2 "${WEBTMP}/all-denied.jsonl"
allDenied="$(cat "${WEBTMP}/results-all-denied.json")"
assert_contains "a run refused every time reached the web zero times" "${allDenied}" '"total": 0'
assert_contains "and its refusals are still on the record" "${allDenied}" '"denied": 3'
assert_contains "refusals never spend the allowance, so a blocked run is not reported as overspending" \
  "${allDenied}" '"overCap": false'

# A refusal marked ONLY by its text, with no `tool_result_meta` at all. The two marks travel together in
# every refusal on this Mac, but the meta field is the newer of the two and the counter must not go back
# to counting refusals as reach the day a CLI stops emitting it.
cat > "${WEBTMP}/text-denied.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_t1","name":"WebSearch","input":{"query":"x"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"Claude requested permissions to use WebSearch, but you haven't granted it yet.","is_error":true,"tool_use_id":"toolu_t1"}]}}
{"type":"result","total_cost_usd":0.1,"duration_ms":100}
EOF
echo '{"version":6,"results":[{"naturalKey":"a"}]}' > "${WEBTMP}/results-text-denied.json"
record_web_calls "${WEBTMP}/results-text-denied.json" 5 "${WEBTMP}/text-denied.jsonl"
textDenied="$(cat "${WEBTMP}/results-text-denied.json")"
assert_contains "a refusal stated only in the result text is still a refusal" \
  "${textDenied}" '"denied": 1'
assert_contains "so it does not reach the total either" "${textDenied}" '"total": 0'

# The incomplete path follows the same rule the total already follows: a partial refusal count must not
# be readable as the run's refusal count by a reader reaching for the field it always reads.
echo '{"version":6,"results":[{"naturalKey":"a"}]}' > "${WEBTMP}/results-denied-partial.json"
record_web_calls "${WEBTMP}/results-denied-partial.json" 5 "${WEBTMP}/all-denied.jsonl" "${WEBTMP}/gone.jsonl"
deniedPartial="$(cat "${WEBTMP}/results-denied-partial.json")"
assert_contains "an incomplete count carries its refusals as a partial figure" \
  "${deniedPartial}" '"partialDenied": 3'
if [[ "${deniedPartial}" == *'"denied":'* ]]; then
  echo "FAIL - an incomplete count published a 'denied' a reader would take for the run's own"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - and publishes no 'denied' at all on the incomplete path"
fi

# --- #1678: the committed contract fixtures carry the shape these writers actually produce -----------
#
# `fixtures/prep-results/run-metadata-complete-v8.json` and `run-metadata-partial-v8.json` are what the Swift
# side asserts against, and a fixture nobody generated is a shape somebody imagined. It would then defend
# that imagined shape forever, and no reviewer could see the difference (L48).
#
# So the fixtures are compared, key for key, against what these three functions emit right now. Values are
# deliberately NOT compared: the committed figures come from the run measured on the live store on
# 2026-08-07 and the base results file decides items/parties/allowance. The KEY SET is the contract, and
# it is the key set the honest/partial split lives in: a `usd` appearing on the incomplete path, or a
# `partialTotal` disappearing from it, changes it here and fails.

FIXTMP="$(fixture_scratch_dir)"
FIXTURES="$(cd "${SCRIPT_DIR}/../../.." && pwd)/fixtures/prep-results"

emit_tool_uses() {
  local file="$1" name="$2" count="$3" i url
  for ((i = 0; i < count; i++)); do
    if [[ "${name}" == "WebFetch" ]]; then
      url="{\"url\":\"https://example.org/events/${i}\"}"
    else
      url="{\"query\":\"contact ${i}\"}"
    fi
    printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"${name}\",\"input\":${url}}]}}" >> "${file}"
  done
}

: > "${FIXTMP}/s1.jsonl"; emit_tool_uses "${FIXTMP}/s1.jsonl" WebFetch 10; emit_tool_uses "${FIXTMP}/s1.jsonl" WebSearch 11
: > "${FIXTMP}/s2.jsonl"; emit_tool_uses "${FIXTMP}/s2.jsonl" WebFetch 9;  emit_tool_uses "${FIXTMP}/s2.jsonl" WebSearch 10
: > "${FIXTMP}/s3.jsonl"; emit_tool_uses "${FIXTMP}/s3.jsonl" WebFetch 9;  emit_tool_uses "${FIXTMP}/s3.jsonl" WebSearch 10
printf '%s\n' '{"type":"result","subtype":"success","total_cost_usd":1.802411,"duration_ms":389906}' >> "${FIXTMP}/s1.jsonl"
printf '%s\n' '{"type":"result","subtype":"success","total_cost_usd":1.798506,"duration_ms":361204}' >> "${FIXTMP}/s2.jsonl"
printf '%s\n' '{"type":"result","subtype":"success","total_cost_usd":1.794506,"duration_ms":342117}' >> "${FIXTMP}/s3.jsonl"

# Sorted key list of one top-level object in a JSON file, so the comparison is order-independent.
keys_of() {
  node -e '
    const fs = require("fs");
    const [file, key] = process.argv.slice(1);
    const value = JSON.parse(fs.readFileSync(file, "utf8"))[key];
    if (value === undefined) { console.log("MISSING"); process.exit(0); }
    console.log(typeof value === "object" ? Object.keys(value).sort().join(",") : "scalar");
  ' "$1" "$2"
}

# #2762: with OVERTURE_RUN_CONTENDED set, because prep-run.sh always sets it to one value or the other.
# Left unset here the comparison would describe a file no real run produces, and the checked-in fixtures
# are the spec anyone reads before changing this shape.
cp "${FIXTURES}/v8.json" "${FIXTMP}/fresh-complete.json"
record_model "${FIXTMP}/fresh-complete.json" "sonnet"
OVERTURE_RUN_CONTENDED=0 record_run_cost "${FIXTMP}/fresh-complete.json" "${FIXTMP}/s1.jsonl" "${FIXTMP}/s2.jsonl" "${FIXTMP}/s3.jsonl"
record_web_calls "${FIXTMP}/fresh-complete.json" 15 "${FIXTMP}/s1.jsonl" "${FIXTMP}/s2.jsonl" "${FIXTMP}/s3.jsonl"

cp "${FIXTURES}/v8.json" "${FIXTMP}/fresh-partial.json"
record_model "${FIXTMP}/fresh-partial.json" "sonnet"
OVERTURE_RUN_CONTENDED=0 record_run_cost "${FIXTMP}/fresh-partial.json" "${FIXTMP}/s1.jsonl" "${FIXTMP}/s2.jsonl" "${FIXTMP}/never-appeared.jsonl"
record_web_calls "${FIXTMP}/fresh-partial.json" 15 "${FIXTMP}/s1.jsonl" "${FIXTMP}/s2.jsonl" "${FIXTMP}/never-appeared.jsonl"

for pair in "model:record_model" "runCost:record_run_cost" "webCalls:record_web_calls"; do
  key="${pair%%:*}"
  writer="${pair##*:}"

  fresh_keys="$(keys_of "${FIXTMP}/fresh-complete.json" "${key}")"
  assert_equals "the complete fixture's ${key} is the shape ${writer} writes" \
    "${fresh_keys}" "$(keys_of "${FIXTURES}/run-metadata-complete-v8.json" "${key}")"
  if [[ "${fresh_keys}" == "MISSING" ]]; then
    echo "FAIL - ${key} is absent from a freshly written file, so this comparison proves nothing"
    FAILURES=$((FAILURES + 1))
  fi

  assert_equals "the partial fixture's ${key} is the shape ${writer} writes on a partial run" \
    "$(keys_of "${FIXTMP}/fresh-partial.json" "${key}")" \
    "$(keys_of "${FIXTURES}/run-metadata-partial-v8.json" "${key}")"
done

# And the split itself, asserted on the committed fixtures rather than on a temp file, because those are
# what the Swift side and any future reader actually consult.
complete_fixture="$(cat "${FIXTURES}/run-metadata-complete-v8.json")"
partial_fixture="$(cat "${FIXTURES}/run-metadata-partial-v8.json")"
assert_contains "the complete fixture states a real cost" "${complete_fixture}" '"usd": 5.395423'
assert_contains "the complete fixture states a real web call total" "${complete_fixture}" '"total": 59'
if [[ "${partial_fixture}" == *'"usd":'* || "${partial_fixture}" == *'"total":'* ]]; then
  echo "FAIL - the partial fixture publishes a figure a reader could take for the run's total"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - the partial fixture publishes no figure that could be read as the run's total"
fi
assert_contains "the partial fixture says what it DID see, under its own name" \
  "${partial_fixture}" '"partialUsd": 3.600917'

# --- ONE definition of "this stream finished" (#3357 Phase 1.1, L263) -------------------------------
#
# `record_web_calls` and `record_run_cost` read the SAME event files and answered differently about
# whether the run finished. web_calls counted a stream as reported if its file merely PARSED;
# run_cost required a terminal result envelope.
#
# The cost of the disagreement, measured on a real archive (`check-run-archives/20260830-205244/`): a
# 97 item queue, a 90 result file, `runCost` reporting `streams: 10, streamsRecorded: 9,
# recorded: false`, and `webCalls` reporting `recorded: true, overCap: false, streams: 10` about the
# SAME run. Seven shows were silently lost, and the web call reading called that run complete.
#
# The existing incomplete-path case above uses a MISSING file, which both definitions already agree
# about. This is the case that separated them: a stream killed part way flushes plenty of valid JSONL
# and no envelope, so every line parses and nothing finished. That is the commonest way a run dies here.

cat > "${WEBTMP}/events-killed.jsonl" <<'KILLED'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebFetch","input":{"url":"https://b.example"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebSearch","input":{"query":"someone"}}]}}
KILLED

echo '{"version":6,"results":[{"naturalKey":"a"}]}' > "${WEBTMP}/killed-web.json"
echo '{"version":6,"results":[{"naturalKey":"a"}]}' > "${WEBTMP}/killed-cost.json"
record_web_calls "${WEBTMP}/killed-web.json" 18 "${WEBTMP}/events.jsonl" "${WEBTMP}/events-killed.jsonl"
record_run_cost "${WEBTMP}/killed-cost.json" "${WEBTMP}/events.jsonl" "${WEBTMP}/events-killed.jsonl"
killed_web="$(cat "${WEBTMP}/killed-web.json")"
killed_cost="$(cat "${WEBTMP}/killed-cost.json")"

# The one claim, in both halves: they agree the run did not finish, over the same streams.
assert_contains "a stream killed before its envelope is incomplete to the cost reading" \
  "${killed_cost}" '"recorded": false'
assert_contains "and incomplete to the web call reading, over the SAME streams" \
  "${killed_web}" '"recorded": false'

# Neither publishes the number a reader would take as the real one. A partial total is worse than none,
# because it reads as a measurement and nothing beside it says it is short (L98, L11).
if [[ "${killed_cost}" == *'"usd":'* ]]; then
  echo "FAIL - a run killed before its envelope still published a 'usd' downstream would read as real"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - a killed run publishes no 'usd' at all"
fi
if [[ "${killed_web}" == *'"total":'* ]]; then
  echo "FAIL - a run killed before its envelope still published a 'total' downstream would read as real"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - and no 'total' at all"
fi

# What the run DID see survives, so an incomplete reading is not an empty one, and it says how many of
# how many streams actually reported.
assert_contains "the partial per-route counts survive" "${killed_web}" '"byRoute"'
assert_contains "and it says how many of how many streams reported" \
  "${killed_web}" '"streamsReported": 1'

rm -rf "${FIXTMP}"

# --- #3357 Phase 1.3 and 1.5: per item attribution, and the watchdog kill record ---------------------
#
# These cases sit ABOVE the verdict deliberately. `FAILURES` is summed and this file exits a few lines
# down, so a case appended BELOW that prints its FAIL text and is never counted: the fixture exits 0
# with failures on screen. That happened while proving #3443 and is why the file now ends with its
# verdict.

ATTRTMP="$(fixture_scratch_dir)"

# One stream, two items, in the shape the runbook asks for: research, write, research, write. The Write
# content is the cumulative results file, so the SECOND write names both keys and only the new one is
# the item it just finished.
{
  printf '{"message":{"content":[{"type":"tool_use","name":"WebSearch","input":{"query":"kestrel quartet contact"}}]}}\n'
  printf '{"message":{"content":[{"type":"tool_use","name":"WebFetch","input":{"url":"https://kestrelquartet.example/about"}}]}}\n'
  printf '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"content":"{\\"results\\":[{\\"naturalKey\\":\\"kestrel|2027-04-18|rowan\\"}]}"}}]}}\n'
  printf '{"message":{"content":[{"type":"tool_use","name":"WebSearch","input":{"query":"thornfield ensemble producer"}}]}}\n'
  printf '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"content":"{\\"results\\":[{\\"naturalKey\\":\\"kestrel|2027-04-18|rowan\\"},{\\"naturalKey\\":\\"thornfield|2027-05-02|rowan\\"}]}"}}]}}\n'
  printf '{"type":"result","total_cost_usd":1.5}\n'
} > "${ATTRTMP}/events-chunk-1.jsonl"

record_item_attribution "${ATTRTMP}/attr.json" "${ATTRTMP}/no-kills.json" \
  "${ATTRTMP}/events-chunk-1.jsonl" > "${ATTRTMP}/attr.out" 2>&1
attr="$(cat "${ATTRTMP}/attr.json" 2>/dev/null)"

assert_contains "the first show is named" "${attr}" 'kestrel|2027-04-18|rowan'
assert_contains "the second show is named" "${attr}" 'thornfield|2027-05-02|rowan'
assert_contains "a SEARCH is attributed, not only a fetch" "${attr}" 'kestrel quartet contact'
assert_contains "and so is a fetch" "${attr}" 'https://kestrelquartet.example/about'
assert_contains "the stream reports as attributed" "${attr}" '"outcome": "attributed"'

# THE POINT OF THE WHOLE DERIVATION: the calls land on the item they were made for, not on the chunk.
# Without this the two items share one undifferentiated list and a starved show is invisible inside a
# busy chunk, which is the reading `what-the-check-searched.sh` exists to make possible.
second_item_block="${attr#*thornfield|2027-05-02|rowan}"
assert_contains "the second show carries its OWN search" "${second_item_block}" 'thornfield ensemble producer'
if [[ "${second_item_block}" == *"kestrel quartet contact"* ]]; then
  echo "FAIL - the first show's search was attributed to the second one as well"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - and not the first show's"
fi

# A Write naming SEVERAL new keys at once cannot say which of them the preceding calls were for, so
# they stay unattributed. Guessing is what would hide a starved show inside a busy chunk, which is the
# one reading this whole derivation exists to make possible.
#
# Added because a mutation found it missing: relaxing `fresh.length === 1` to `>= 1` SURVIVED, so
# nothing was holding the batched case at all.
{
  printf '{"message":{"content":[{"type":"tool_use","name":"WebSearch","input":{"query":"one search, two shows"}}]}}\n'
  printf '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"content":"{\\"results\\":[{\\"naturalKey\\":\\"alpha|2027-06-01|rowan\\"},{\\"naturalKey\\":\\"beta|2027-06-02|rowan\\"}]}"}}]}}\n'
  printf '{"type":"result","total_cost_usd":1.5}\n'
} > "${ATTRTMP}/events-chunk-batched.jsonl"

record_item_attribution "${ATTRTMP}/attr-batched.json" "" \
  "${ATTRTMP}/events-chunk-batched.jsonl" >/dev/null 2>&1
batched="$(cat "${ATTRTMP}/attr-batched.json")"
assert_contains "a Write naming two new shows attributes the calls to neither" \
  "${batched}" '"unattributedCalls"'
batched_items="${batched#*\"items\": [}"
batched_items="${batched_items%%]*}"
if [[ "${batched_items}" == *"alpha|2027-06-01|rowan"* ]]; then
  echo "FAIL - a batched Write claimed one of its two shows as the item"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - and names neither of them as the item it just finished"
fi
assert_contains "and the call itself is kept rather than dropped" \
  "${batched}" 'one search, two shows'

# A stream that reported calls and never named an item is UNATTRIBUTABLE, and a stream that could not be
# read at all is UNMEASURED. Two states, never one: an unreadable stream and a stream with nothing in it
# are different facts and only one of them is a finding (L98, L11).
printf '{"message":{"content":[{"type":"tool_use","name":"WebSearch","input":{"query":"nobody"}}]}}\n' \
  > "${ATTRTMP}/events-chunk-2.jsonl"
record_item_attribution "${ATTRTMP}/attr2.json" "" "${ATTRTMP}/events-chunk-2.jsonl" >/dev/null 2>&1
assert_contains "a stream that named no item is unattributable" \
  "$(cat "${ATTRTMP}/attr2.json")" '"outcome": "unattributable"'
assert_contains "and its calls are kept rather than dropped" \
  "$(cat "${ATTRTMP}/attr2.json")" '"unattributedCalls"'

record_item_attribution "${ATTRTMP}/attr3.json" "" "${ATTRTMP}/no-such-stream.jsonl" >/dev/null 2>&1
assert_contains "a stream that is not there is unmeasured, never clean" \
  "$(cat "${ATTRTMP}/attr3.json")" '"outcome": "unmeasured"'
assert_contains "and the run says so in its totals" "$(cat "${ATTRTMP}/attr3.json")" '"unmeasured": 1'

# #3357 Phase 1.5. A killed chunk is a confound in any comparison between runs, and its only trace used
# to be a line on a terminal that closes (L148).
# `record_watchdog_kill` lives in stuck-tool-call.sh, beside the watchdog that calls it, and this
# fixture covers the pair because the ITEM half of the record is computed in models.sh. Sourced here
# rather than moving the function, so the writer stays next to the only thing that fires it.
# shellcheck source=stuck-tool-call.sh
source "${SCRIPT_DIR}/stuck-tool-call.sh"

KILLS="${ATTRTMP}/kills.json"
SLOT_WATCHDOG_KILLS="${KILLS}" record_watchdog_kill 1 187
SLOT_WATCHDOG_KILLS="${KILLS}" record_watchdog_kill 3 191
assert_contains "a kill is recorded with its chunk" "$(cat "${KILLS}")" '"chunk":1'
assert_contains "and a second kill does not erase the first" "$(cat "${KILLS}")" '"chunk":3'
assert_contains "and how long the request had been in flight" "$(cat "${KILLS}")" '"requestInFlightSeconds":187'

record_item_attribution "${ATTRTMP}/attr4.json" "${KILLS}" "${ATTRTMP}/events-chunk-1.jsonl" \
  > "${ATTRTMP}/attr4.out" 2>&1
attr4="$(cat "${ATTRTMP}/attr4.json")"
assert_contains "the kills reach the sidecar" "${attr4}" '"watchdogKills"'
# The ITEM half of Phase 1.5, and the reason the kill record parses nothing itself: chunk 1 is the
# stream this pass already walked, so what it had written is known here without a second parser (L263).
assert_contains "and a killed chunk names what it had already written" \
  "${attr4}" '"itemsAlreadyWritten"'
assert_contains "which is the item that stream finished" "${attr4}" 'kestrel|2027-04-18|rowan'
assert_contains "a run with a kill in it says it is not comparison evidence" \
  "$(cat "${ATTRTMP}/attr4.out")" "not usable as comparison evidence"

# A run nothing killed says zero, and that is a measurement. Absent and unreadable must not read the
# same as it, which is why `killsReadable` is its own field.
assert_contains "a run with no kills reports the fact" "${attr}" '"killsReadable": true'
if [[ "${attr}" == *'"watchdogKills": []'* ]]; then
  echo "ok - and an empty kill list, not a missing one"
else
  echo "FAIL - a run with no kills did not report an empty list"
  FAILURES=$((FAILURES + 1))
fi

rm -rf "${ATTRTMP}"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all models.sh checks passed"
