#!/usr/bin/env bash
set -uo pipefail

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

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

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
WEBTMP="$(mktemp -d)"
trap 'rm -rf "${WEBTMP}"' EXIT

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

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all models.sh checks passed"
