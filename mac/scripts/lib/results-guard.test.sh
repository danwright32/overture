#!/usr/bin/env bash
set -uo pipefail

# #856: a detached run that exits without results must write an honest failure, not vanish.
#
# Three times in one evening a run did real work and produced nothing usable: it stopped to ask a
# question (#847), it hit a broken prompt (#853), and in between it left the app polling for a file that
# never came (#848). Each time the fix was to instruct the model better. Instructions are not a
# guarantee: a run can still exit without writing its results for a reason nobody has thought of yet, and
# when it does, the work is gone and the app is left guessing.
#
# The SCRIPT knows what it asked for (it wrote the queue) and can see what came back. So the script
# closes the hole itself: every queued sourceId that did not come back gets an honest `not_read` result,
# with the tail of the run log. A lost run becomes a reported failure rather than a silence, structurally,
# whatever the model does.

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
source "${SCRIPT_DIR}/results-guard.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

QUEUE="${TMP}/queue.json"
RESULTS="${TMP}/results.json"
LOG="${TMP}/run.log"

write_queue() {
  cat > "${QUEUE}" <<'JSON'
{"version":1,"generatedAt":"2026-07-12T00:00:00Z","items":[
  {"sourceId":"kaufman","pagePath":"/tmp/a.html"},
  {"sourceId":"bargemusic","pagePath":"/tmp/b.html"}
]}
JSON
}

# Reads a field out of the results file, so every assertion below is about what the APP will actually
# decode, not about the shape of the shell that produced it.
result_field() {
  node -e '
    const j = require(process.argv[1]);
    const r = (j.results || []).find(r => r.sourceId === process.argv[2]);
    console.log(r ? String(r[process.argv[3]] ?? "") : "MISSING");
  ' "${RESULTS}" "$1" "$2" 2>/dev/null
}

verdicts() {
  node -e '
    const j = require(process.argv[1]);
    console.log((j.results || []).map(r => r.sourceId + "=" + r.verdict).sort().join(","));
  ' "${RESULTS}" 2>/dev/null
}

# --- The run vanished entirely: no results file at all ----------------------------------------------
#
# The #847 shape. The model asked a question and exited, so twenty correctly extracted shows were lost
# and the app was left polling for a file that never came. Every source it was given must come back as
# an honest failure.
write_queue
rm -f "${RESULTS}"
printf 'boot\nreading kaufman\nwhat should I do about pagination?\n' > "${LOG}"

ensure_every_queued_source_reported "${QUEUE}" "${RESULTS}" "${LOG}" 0

assert_equals "a run that wrote nothing still reports on every source it was given" \
  "bargemusic=not_read,kaufman=not_read" "$(verdicts)"
assert_contains "and says the run produced nothing, rather than blaming the page" \
  "$(result_field kaufman note)" "produced no results"
assert_contains "and carries the tail of the run log, so the reason is not lost" \
  "$(result_field kaufman note)" "pagination"

# --- The run reported on SOME sources, and dropped the rest -------------------------------------------
#
# The quiet one. A partial results file looks like a success: the app ingests what came back and never
# says a word about what did not. The dropped source keeps its unread flag, so it is retried, but Dan is
# never told it was dropped at all.
write_queue
cat > "${RESULTS}" <<'JSON'
{"version":1,"generatedAt":"2026-07-12T01:00:00Z","results":[
  {"sourceId":"kaufman","verdict":"upcoming_listings","events":[{"title":"A Recital"}],"note":"page 1 of 4"}
]}
JSON
printf 'boot\nread kaufman ok\ncrashed\n' > "${LOG}"

ensure_every_queued_source_reported "${QUEUE}" "${RESULTS}" "${LOG}" 1

assert_equals "the source that came back is untouched, and the dropped one is reported" \
  "bargemusic=not_read,kaufman=upcoming_listings" "$(verdicts)"
assert_equals "the real result's own events survive" "1" \
  "$(node -e 'const j=require(process.argv[1]);console.log(j.results.find(r=>r.sourceId==="kaufman").events.length)' "${RESULTS}")"
assert_equals "and its own note survives" "page 1 of 4" "$(result_field kaufman note)"

# --- Every source reported: do not touch a healthy results file ---------------------------------------
write_queue
cat > "${RESULTS}" <<'JSON'
{"version":1,"generatedAt":"2026-07-12T01:00:00Z","results":[
  {"sourceId":"kaufman","verdict":"all_past","events":[],"note":"between seasons"},
  {"sourceId":"bargemusic","verdict":"upcoming_listings","events":[],"note":""}
]}
JSON
before="$(cat "${RESULTS}")"
ensure_every_queued_source_reported "${QUEUE}" "${RESULTS}" "${LOG}" 0
assert_equals "a complete results file is left exactly as the run wrote it" "${before}" "$(cat "${RESULTS}")"

# --- The results file is CORRUPT ---------------------------------------------------------------------
#
# The worst shape, and a silent one: the app's decode fails, so it ingests nothing and says nothing at
# all. Not even the "finished without producing anything" warning fires, because a freshly written file
# looks like a run that produced results. The corrupt bytes are kept as evidence, and every source is
# reported honestly.
write_queue
printf '%s' '{"version":1,"results":[{"sourceId":"kauf' > "${RESULTS}"
printf 'boot\nout of memory\n' > "${LOG}"

ensure_every_queued_source_reported "${QUEUE}" "${RESULTS}" "${LOG}" 137

assert_equals "an unparsable results file becomes an honest failure for every source" \
  "bargemusic=not_read,kaufman=not_read" "$(verdicts)"
assert_contains "and the corrupt bytes are preserved as evidence, never just overwritten" \
  "$(cat "${RESULTS}.corrupt" 2>/dev/null || echo MISSING)" '{"version":1,"results":[{"sourceId":"kauf'

# --- It must never fail the run it is guarding --------------------------------------------------------
#
# This runs at the very end of a detached run, on the failure path, when things have already gone wrong.
# It is the last thing standing between Dan and a silent loss, so it degrades rather than throws.
write_queue
rm -f "${RESULTS}"
if PATH="/nonexistent" ensure_every_queued_source_reported "${QUEUE}" "${RESULTS}" "${LOG}" 0; then
  echo "ok - a machine with no node degrades quietly instead of failing the run"
else
  echo "FAIL - the guard must never turn a bad run into a worse one"
  FAILURES=$((FAILURES + 1))
fi

if ensure_every_queued_source_reported "${TMP}/no-such-queue.json" "${RESULTS}" "${LOG}" 0; then
  echo "ok - no queue means nothing was asked for, so there is nothing to guard"
else
  echo "FAIL - a missing queue must not fail the run"
  FAILURES=$((FAILURES + 1))
fi

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all results-guard.sh checks passed"
