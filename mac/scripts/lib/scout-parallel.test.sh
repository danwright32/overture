#!/usr/bin/env bash
set -uo pipefail

# #1028: scout-extract on sonnet reads every page and follows each event's detail link, which is
# accurate but slow (16 minutes for 18 sources, wholly sequential). The sources are independent until
# the final reconcile, so the run splits its queue into chunks and drives one claude per chunk
# concurrently. These are the two pure functions that make that safe:
#
#   split_queue_into_chunks   partitions the queue so every sourceId lands in exactly ONE chunk (the
#                             thing that makes the merge a concatenation and idempotency free).
#   merge_chunk_results       unions the per-chunk results back into the one file the app polls, in the
#                             queue's own order, tolerant of a chunk still mid-write.
#
# The orchestration around them (launching, the heartbeat, the results guard) is exercised by the real
# script and the other libs; these tests pin the data mechanics, where a split that dropped a source or
# a merge that lost one would be a silent loss of Dan's shows.

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
source "${SCRIPT_DIR}/scout-parallel.sh"

command -v node >/dev/null 2>&1 || { echo "ok - node absent, scout-parallel degrades (skipped)"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

QUEUE="${TMP}/queue.json"
CHUNKDIR="${TMP}/chunks"
RESULTS="${TMP}/results.json"

# A queue field reader, so assertions are about what a chunk queue actually decodes to.
chunk_field() {
  node -e '
    const j = require(process.argv[1]);
    console.log(String(j[process.argv[2]] ?? ""));
  ' "$1" "$2" 2>/dev/null
}
# All sourceIds in a chunk queue, comma-joined in file order.
chunk_ids() {
  node -e '
    const j = require(process.argv[1]);
    console.log((j.items || []).map(i => i.sourceId).join(","));
  ' "$1" 2>/dev/null
}
# All sourceIds across every chunk-queue-*.json, comma-joined.
all_chunk_ids() {
  node -e '
    const fs = require("fs"), path = require("path");
    const dir = process.argv[1];
    const files = fs.readdirSync(dir).filter(f => /^chunk-queue-\d+\.json$/.test(f)).sort();
    const ids = [];
    for (const f of files) {
      const j = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
      for (const it of (j.items || [])) ids.push(it.sourceId);
    }
    console.log(ids.join(","));
  ' "$1" 2>/dev/null
}
result_ids() {
  node -e '
    const j = require(process.argv[1]);
    console.log((j.results || []).map(r => r.sourceId).join(","));
  ' "$1" 2>/dev/null
}
result_field() {
  node -e '
    const j = require(process.argv[1]);
    const r = (j.results || []).find(r => r.sourceId === process.argv[2]);
    console.log(r ? String(r[process.argv[3]] ?? "") : "MISSING");
  ' "$1" "$2" "$3" 2>/dev/null
}

write_queue() {
  # $1 = number of sources; ids are s1..sN in order.
  local n="$1" i
  {
    printf '{"version":2,"generatedAt":"2026-07-17T10:00:00Z","items":['
    for ((i = 1; i <= n; i++)); do
      [[ $i -gt 1 ]] && printf ','
      printf '{"sourceId":"s%d","pagePath":"/tmp/p%d.html","orgName":"Org %d"}' "$i" "$i" "$i"
    done
    printf ']}\n'
  } > "${QUEUE}"
}

# --- split_queue_into_chunks -------------------------------------------------

echo "--- split_queue_into_chunks"

# Five sources, four-way parallelism: four chunks, sizes 2,1,1,1, contiguous, every id present once.
rm -rf "${CHUNKDIR}"; mkdir -p "${CHUNKDIR}"
write_queue 5
K="$(split_queue_into_chunks "${QUEUE}" 4 "${CHUNKDIR}")"
assert_equals "5 sources over max 4 makes 4 chunks" "4" "${K}"
assert_equals "chunk 1 gets the first two (spreads the remainder to the front)" "s1,s2" "$(chunk_ids "${CHUNKDIR}/chunk-queue-1.json")"
assert_equals "chunk 2 gets the third" "s3" "$(chunk_ids "${CHUNKDIR}/chunk-queue-2.json")"
assert_equals "chunk 4 gets the last" "s5" "$(chunk_ids "${CHUNKDIR}/chunk-queue-4.json")"
assert_equals "every source appears exactly once, in order, across the chunks" "s1,s2,s3,s4,s5" "$(all_chunk_ids "${CHUNKDIR}")"
assert_equals "a chunk queue keeps the parent version" "2" "$(chunk_field "${CHUNKDIR}/chunk-queue-1.json" version)"
assert_equals "a chunk queue keeps the parent generatedAt" "2026-07-17T10:00:00Z" "$(chunk_field "${CHUNKDIR}/chunk-queue-1.json" generatedAt)"

# Fewer sources than the parallelism cap: never make an empty chunk.
rm -rf "${CHUNKDIR}"; mkdir -p "${CHUNKDIR}"
write_queue 2
K="$(split_queue_into_chunks "${QUEUE}" 4 "${CHUNKDIR}")"
assert_equals "2 sources over max 4 makes only 2 chunks, never 4" "2" "${K}"
assert_equals "no chunk is empty" "s1,s2" "$(all_chunk_ids "${CHUNKDIR}")"

# max_parallel of 1 is exactly today's behaviour: one chunk holding the whole queue.
rm -rf "${CHUNKDIR}"; mkdir -p "${CHUNKDIR}"
write_queue 6
K="$(split_queue_into_chunks "${QUEUE}" 1 "${CHUNKDIR}")"
assert_equals "max 1 makes a single chunk (the sequential path, unchanged)" "1" "${K}"
assert_equals "the single chunk holds the entire queue" "s1,s2,s3,s4,s5,s6" "$(chunk_ids "${CHUNKDIR}/chunk-queue-1.json")"

# A pass leaves no chunk-queue file from a bigger previous run to masquerade as this run's work.
rm -rf "${CHUNKDIR}"; mkdir -p "${CHUNKDIR}"
write_queue 6
split_queue_into_chunks "${QUEUE}" 4 "${CHUNKDIR}" >/dev/null
write_queue 2
K="$(split_queue_into_chunks "${QUEUE}" 4 "${CHUNKDIR}")"
assert_equals "a second split reports only its own chunks" "2" "${K}"
assert_equals "a stale chunk from the previous, larger split is gone" "s1,s2" "$(all_chunk_ids "${CHUNKDIR}")"

# --- merge_chunk_results -----------------------------------------------------

echo "--- merge_chunk_results"

# Two chunks each wrote their own results; the merge is their union, in the queue's order.
rm -rf "${CHUNKDIR}"; mkdir -p "${CHUNKDIR}"
write_queue 4
cat > "${CHUNKDIR}/chunk-results-2.json" <<'JSON'
{"version":1,"generatedAt":"2026-07-17T10:05:00Z","results":[
  {"sourceId":"s3","verdict":"all_past","events":[],"note":"between seasons"},
  {"sourceId":"s4","verdict":"upcoming_listings","events":[{"title":"Recital"}],"note":""}
]}
JSON
cat > "${CHUNKDIR}/chunk-results-1.json" <<'JSON'
{"version":1,"generatedAt":"2026-07-17T10:04:00Z","results":[
  {"sourceId":"s1","verdict":"upcoming_listings","events":[{"title":"Gala"}],"note":""},
  {"sourceId":"s2","verdict":"no_dated_content","events":[],"note":"wrong page"}
]}
JSON
merge_chunk_results "${QUEUE}" "${CHUNKDIR}" "${RESULTS}"
assert_equals "the merged results carry every source, ordered by the queue not by chunk" "s1,s2,s3,s4" "$(result_ids "${RESULTS}")"
assert_equals "a source keeps its own chunk's verdict" "all_past" "$(result_field "${RESULTS}" s3 verdict)"
assert_equals "a source keeps its own chunk's note" "wrong page" "$(result_field "${RESULTS}" s2 note)"

# A chunk still mid-write (unparsable) must not zero out or lose the chunks that ARE done.
rm -rf "${CHUNKDIR}"; mkdir -p "${CHUNKDIR}"
write_queue 4
cat > "${CHUNKDIR}/chunk-results-1.json" <<'JSON'
{"version":1,"generatedAt":"2026-07-17T10:04:00Z","results":[
  {"sourceId":"s1","verdict":"upcoming_listings","events":[],"note":""},
  {"sourceId":"s2","verdict":"all_past","events":[],"note":""}
]}
JSON
printf '{"version":1,"results":[{"sourceId":"s3", ' > "${CHUNKDIR}/chunk-results-2.json"   # truncated mid-write
merge_chunk_results "${QUEUE}" "${CHUNKDIR}" "${RESULTS}"
assert_equals "a half-written chunk is skipped, the finished chunk still lands" "s1,s2" "$(result_ids "${RESULTS}")"

# No chunk results yet at all: leave the results file untouched rather than writing an empty one that
# would read as a run that finished and found nothing (the progress-watcher counts this file).
rm -rf "${CHUNKDIR}"; mkdir -p "${CHUNKDIR}"
write_queue 4
printf 'SENTINEL' > "${RESULTS}"
merge_chunk_results "${QUEUE}" "${CHUNKDIR}" "${RESULTS}"
assert_equals "with no parseable chunk results, the existing results file is left as it was" "SENTINEL" "$(cat "${RESULTS}")"

# The merged file is valid JSON carrying a generatedAt, so the app can decode it and the model stamp
# can be added afterward.
rm -rf "${CHUNKDIR}"; mkdir -p "${CHUNKDIR}"
write_queue 2
cat > "${CHUNKDIR}/chunk-results-1.json" <<'JSON'
{"version":1,"generatedAt":"2026-07-17T10:04:00Z","results":[
  {"sourceId":"s1","verdict":"all_past","events":[],"note":""},
  {"sourceId":"s2","verdict":"all_past","events":[],"note":""}
]}
JSON
merge_chunk_results "${QUEUE}" "${CHUNKDIR}" "${RESULTS}"
GENERATED_AT="$(chunk_field "${RESULTS}" generatedAt)"
if [[ -n "${GENERATED_AT}" ]]; then
  echo "ok - the merged results file carries a non-empty generatedAt"
else
  echo "FAIL - the merged results file has no generatedAt"
  FAILURES=$((FAILURES + 1))
fi

# --- failure isolation: a dead chunk does not lose its sources ---------------
#
# This is the guarantee the parallel path exists to keep. When one chunk's claude dies having written
# nothing (a crash, an API error), the runner still merges what the OTHER chunks produced, then runs the
# results guard against the FULL queue. The dead chunk's sources must come home as honest not_read, and
# the surviving chunk's sources must keep exactly what they said. This composes the real functions the
# runner calls, in the runner's order, so it proves the composition and not just the parts.

echo "--- failure isolation (merge + results guard, as the runner composes them)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/results-guard.sh"

rm -rf "${CHUNKDIR}"; mkdir -p "${CHUNKDIR}"
write_queue 4
K="$(split_queue_into_chunks "${QUEUE}" 2 "${CHUNKDIR}")"
assert_equals "4 sources over max 2 makes 2 chunks" "2" "${K}"
# Chunk 1 (s1, s2) finished and wrote its results. Chunk 2 (s3, s4) died writing nothing at all: no
# chunk-results-2.json exists.
cat > "${CHUNKDIR}/chunk-results-1.json" <<'JSON'
{"version":1,"generatedAt":"2026-07-17T10:06:00Z","results":[
  {"sourceId":"s1","verdict":"upcoming_listings","events":[{"title":"Gala"}],"note":""},
  {"sourceId":"s2","verdict":"all_past","events":[],"note":"between seasons"}
]}
JSON
LOG="${TMP}/run.log"
printf 'chunk 2 process died: API error 529\n' > "${LOG}"

merge_chunk_results "${QUEUE}" "${CHUNKDIR}" "${RESULTS}"
assert_equals "the merge carries only the sources a live chunk produced" "s1,s2" "$(result_ids "${RESULTS}")"

# The runner then runs the guard against the FULL queue, exactly as scout-extract-run.sh does.
ensure_every_queued_source_reported "${QUEUE}" "${RESULTS}" "${LOG}" "0"
assert_equals "after the guard, every queued source has a result" "s1,s2,s3,s4" "$(result_ids "${RESULTS}")"
assert_equals "a source the live chunk read keeps its own verdict" "upcoming_listings" "$(result_field "${RESULTS}" s1 verdict)"
assert_equals "a source from the dead chunk comes home as not_read, never lost" "not_read" "$(result_field "${RESULTS}" s3 verdict)"
assert_equals "the other dead-chunk source too" "not_read" "$(result_field "${RESULTS}" s4 verdict)"
assert_contains "the not_read note carries the reason from the run log" "$(result_field "${RESULTS}" s3 note)" "API error 529"
assert_equals "the guard reports that sources were missing, so the runner can fail loud" "1" "${RESULTS_MISSING_SOURCES}"

# ---------------------------------------------------------------------------
# #1597: the reachability check reuses this same merge. Its queue keys items by `naturalKey`, not
# `sourceId`, and its results file is version 6, so both are parameters now. A near-identical copy of
# this function for Prep would be a second thing to keep in step with the first, and the drift would be
# invisible until a real run silently lost a show.
# ---------------------------------------------------------------------------
echo
echo "--- the prep-shaped merge (#1597) ---"

PREPTMP="$(mktemp -d)"

cat > "${PREPTMP}/prep-queue.json" <<'EOF'
{"version":6,"generatedAt":"2026-07-27T00:00:00Z","items":[
  {"naturalKey":"a|2026-09-12|hall","groupName":"A","discipline":"theater","priorRelationship":"none"},
  {"naturalKey":"b|2026-09-13|hall","groupName":"B","discipline":"theater","priorRelationship":"none"},
  {"naturalKey":"c|2026-09-14|hall","groupName":"C","discipline":"theater","priorRelationship":"none"}
]}
EOF

mkdir -p "${PREPTMP}/chunks"
cat > "${PREPTMP}/chunks/chunk-results-1.json" <<'EOF'
{"version":6,"generatedAt":"2026-07-27T00:05:00Z","results":[
  {"naturalKey":"c|2026-09-14|hall","contacts":[{"email":"c@example.org"}]}
]}
EOF
cat > "${PREPTMP}/chunks/chunk-results-2.json" <<'EOF'
{"version":6,"generatedAt":"2026-07-27T00:06:00Z","results":[
  {"naturalKey":"a|2026-09-12|hall","contacts":[{"email":"a@example.org"}]}
]}
EOF

prep_keys() {
  node -e 'const r=require(process.argv[1]);console.log(r.results.map(x=>x.naturalKey).join(" "))' \
    "${PREPTMP}/prep-results.json" 2>/dev/null
}

merge_chunk_results "${PREPTMP}/prep-queue.json" "${PREPTMP}/chunks" \
  "${PREPTMP}/prep-results.json" naturalKey 6

assert_contains "the merged prep results carry the prep version, not the scout one" \
  "$(cat "${PREPTMP}/prep-results.json" 2>/dev/null)" '"version": 6'
# Queue order, not chunk-file order: chunk 1 held the LAST show and chunk 2 the first.
assert_equals "the merged prep results are in queue order, keyed by naturalKey" \
  "a|2026-09-12|hall c|2026-09-14|hall" "$(prep_keys)"
# The show no chunk reported is simply absent, never invented as an empty answer. Marking it "checked,
# nobody home" would lock it out of a re-check for 90 days on evidence nobody ever gathered.
assert_equals "a show no chunk answered is left out rather than invented" \
  "absent" \
  "$(node -e 'const r=require(process.argv[1]);console.log(r.results.some(x=>x.naturalKey==="b|2026-09-13|hall")?"present":"absent")' "${PREPTMP}/prep-results.json" 2>/dev/null)"

# A chunk caught mid-rewrite must not zero the file: the app polls it and the progress count is its length.
printf '{"version":6,"resul' > "${PREPTMP}/chunks/chunk-results-3.json"
merge_chunk_results "${PREPTMP}/prep-queue.json" "${PREPTMP}/chunks" \
  "${PREPTMP}/prep-results.json" naturalKey 6
assert_equals "a half-written chunk is skipped, and the good results survive" \
  "a|2026-09-12|hall c|2026-09-14|hall" "$(prep_keys)"

# Nothing parseable at all leaves the previous file untouched rather than writing an empty one, which
# would read as a run that finished and found nobody.
rm -f "${PREPTMP}/chunks"/chunk-results-1.json "${PREPTMP}/chunks"/chunk-results-2.json
merge_chunk_results "${PREPTMP}/prep-queue.json" "${PREPTMP}/chunks" \
  "${PREPTMP}/prep-results.json" naturalKey 6
assert_equals "with every chunk gone the last good results are left alone, not emptied" \
  "a|2026-09-12|hall c|2026-09-14|hall" "$(prep_keys)"

rm -rf "${PREPTMP}"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "scout-parallel.test.sh: all assertions passed"
  exit 0
else
  echo "scout-parallel.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
