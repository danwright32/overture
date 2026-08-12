#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"

# Two cases below run the guards with PATH pointing at a directory that holds nothing, to prove they
# report a failure rather than passing silently when there is no node to read the results with. Bash
# writes "node: command not found" while that happens, which is the same thing it writes for a mistyped
# assertion, so this declares the absence is the thing being rehearsed (#2501). It names only node: any
# other unresolved command in this fixture still fails the run.
echo "shell-fixture-expects-missing-command: node"

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

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ -n "${haystack}" && "${haystack}" != *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    # An EMPTY haystack fails too: nothing written at all would otherwise satisfy every
    # not-contains check here while the guard was doing nothing.
    echo "  expected not to contain: ${needle}"
    echo "  in: ${haystack}"
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

# #1757: the note is shown directly beneath the app's own line for a not_read verdict, which already
# says the page has not been read and that the next scout will try it again. Both sentences were in
# this note too, word for word, so Dan read them twice one line apart. This note says HOW the run
# ended, which is the one thing the app cannot know, and leaves the rest to the line above it.
assert_not_contains "and leaves the page's own state to the app's line, rather than saying it twice" \
  "$(result_field kaufman note)" "It has NOT been read"
assert_not_contains "and does not promise the next scout, which the app's line already promises" \
  "$(result_field kaufman note)" "next scout"

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
  "$(cat "${RESULTS}".*.corrupt 2>/dev/null || echo MISSING)" '{"version":1,"results":[{"sourceId":"kauf'

# #911: and a SECOND bad run must not destroy the first one's evidence.
#
# The name was fixed (`<results>.corrupt`), so two bad runs in a week left only the most recent, with
# nothing anywhere saying an earlier one had been lost. The failure that is hardest to diagnose (an
# intermittent one) is exactly the failure whose evidence that destroyed, and #868's whole point was that
# these bytes ARE the evidence.
printf '%s' '{"version":1,"results":[{"sourceId":"SECOND RUN, DIFFERENT GARBAGE' > "${RESULTS}"
printf 'boot\nsegfault\n' > "${LOG}"

ensure_every_queued_source_reported "${QUEUE}" "${RESULTS}" "${LOG}" 139

assert_equals "a second unreadable run keeps its own evidence AND the first run's" \
  "2" "$(ls "${RESULTS}".*.corrupt 2>/dev/null | wc -l | tr -d ' ')"
assert_contains "the first run's bytes are still there, unharmed" \
  "$(cat "${RESULTS}".*.corrupt 2>/dev/null)" '{"version":1,"results":[{"sourceId":"kauf'
assert_contains "and the second run's bytes are there too" \
  "$(cat "${RESULTS}".*.corrupt 2>/dev/null)" 'SECOND RUN, DIFFERENT GARBAGE'

# The sweep that owns these files (HandoffCleanup, #821) matches on a `.corrupt` suffix, so a stamped name
# is pruned on exactly the same 14-day rule and cannot pile up forever. If this ever stops being true, the
# stamped copies become immortal.
for f in "${RESULTS}".*.corrupt; do
  assert_equals "a stamped copy still ends in .corrupt, so the 14-day sweep still owns it" \
    "corrupt" "${f##*.}"
done
rm -f "${RESULTS}".*.corrupt

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

# --- quarantine_unreadable_results (#868) -------------------------------------------------------------
#
# The prep and reply runs have no per-item failure to synthesize: an empty prep result would CLAIM the
# run researched a show and found nobody, about a show nobody looked at. So they get the other half of
# the guarantee instead.
#
# A results file that does not parse is not results, and leaving it in place is the quietest failure in
# the app. The file is FRESH, so the app reads it as a run that produced results, its decode fails, and
# `guard let ... else { return }` returns in silence: no warning, no error, nothing. The existing "the
# run finished but didn't produce any results" message, which already carries the log tail, never fires,
# precisely BECAUSE a file is sitting there.
#
# Moving it aside restores that message. The bytes are kept, because they are the only evidence of what
# the run actually did.

PREP_RESULTS="${TMP}/prep-results.json"

# The silent black hole: unparsable results.
printf '%s' '{"version":6,"results":[{"naturalKey":"aurora|2026-03-10|carn' > "${PREP_RESULTS}"
quarantine_unreadable_results "${PREP_RESULTS}"

if [[ -f "${PREP_RESULTS}" ]]; then
  echo "FAIL - an unparsable results file must not be left where the app will read it as a fresh success"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - an unparsable results file is moved aside, so the app's empty-run warning fires instead of silence"
fi
assert_contains "and its bytes are kept as evidence of what the run actually did" \
  "$(cat "${PREP_RESULTS}".*.corrupt 2>/dev/null || echo MISSING)" '"naturalKey":"aurora|2026-03-10|carn'

# #911: the same on this path. Two prep runs that both came back garbled must leave two files, not one.
printf '%s' '{"version":6,"results":[{"naturalKey":"A SECOND, DIFFERENT FAILURE' > "${PREP_RESULTS}"
quarantine_unreadable_results "${PREP_RESULTS}"

assert_equals "a second unreadable prep run does not overwrite the first one's evidence" \
  "2" "$(ls "${PREP_RESULTS}".*.corrupt 2>/dev/null | wc -l | tr -d ' ')"
assert_contains "the first prep run's bytes survive" \
  "$(cat "${PREP_RESULTS}".*.corrupt 2>/dev/null)" '"naturalKey":"aurora|2026-03-10|carn'
assert_contains "and so do the second's" \
  "$(cat "${PREP_RESULTS}".*.corrupt 2>/dev/null)" 'A SECOND, DIFFERENT FAILURE'
rm -f "${PREP_RESULTS}".*.corrupt

# A GOOD results file must never be touched. This runs on every run, including every successful one, so
# a false positive here would throw away Dan's drafts.
cat > "${PREP_RESULTS}" <<'JSON'
{"version":6,"generatedAt":"2026-07-12T00:00:00Z","results":[
  {"naturalKey":"aurora|2026-03-10|carnegie-hall","contacts":[],"draft":{"subject":"S","body":"B","variant":"rate_stated"}}
]}
JSON
good_before="$(cat "${PREP_RESULTS}")"
quarantine_unreadable_results "${PREP_RESULTS}"
assert_equals "a results file that parses is left exactly as the run wrote it" \
  "${good_before}" "$(cat "${PREP_RESULTS}" 2>/dev/null || echo GONE)"

# An empty results array is a legitimate answer (the run found nothing), not a corrupt file.
printf '%s' '{"version":6,"generatedAt":"2026-07-12T00:00:00Z","results":[]}' > "${PREP_RESULTS}"
quarantine_unreadable_results "${PREP_RESULTS}"
assert_equals "an empty but valid results file is not corrupt" \
  '{"version":6,"generatedAt":"2026-07-12T00:00:00Z","results":[]}' \
  "$(cat "${PREP_RESULTS}" 2>/dev/null || echo GONE)"

# Never make a bad run worse: no file, and no node.
rm -f "${PREP_RESULTS}"
if quarantine_unreadable_results "${PREP_RESULTS}"; then
  echo "ok - no results file at all is already handled on its own path, so this is a no-op"
else
  echo "FAIL - a missing results file must not fail the run"
  FAILURES=$((FAILURES + 1))
fi

printf '%s' 'not json {' > "${PREP_RESULTS}"
if PATH="/nonexistent" quarantine_unreadable_results "${PREP_RESULTS}"; then
  echo "ok - a machine with no node degrades quietly instead of failing the run"
else
  echo "FAIL - the guard must never turn a bad run into a worse one"
  FAILURES=$((FAILURES + 1))
fi

# --- every runner is actually wired up ---------------------------------------------------------------
#
# A guard no runner calls is worse than none: it reads as solved while every run still fails the same way.
RUNNERS_DIR="${SCRIPT_DIR}/.."
for script in prep-run.sh reply-classify-run.sh scout-extract-run.sh; do
  body="$(cat "${RUNNERS_DIR}/${script}")"
  assert_contains "${script} sources the shared guard" "${body}" 'lib/results-guard.sh'
  # #856/#868: under set -e a dead claude took the whole script down at that line, before anything could
  # notice what had been lost. The status has to be CAPTURED for any guard to run at all.
  #
  # #1597: prep-run.sh now captures it one level down, inside reap_one_claude (`|| REAPED_STATUS=$?`),
  # because the chunked path reaps up to ten of them. Both spellings are the same claim, so either
  # satisfies this; what must never appear is a bare invocation whose failure trips set -e.
  if [[ "${body}" == *'CLAUDE_STATUS=$?'* || "${body}" == *'REAPED_STATUS=$?'* ]]; then
    echo "ok - ${script} captures claude's exit status instead of dying on it"
  else
    echo "FAIL - ${script} captures claude's exit status instead of dying on it"
    FAILURES=$((FAILURES + 1))
  fi
done

# The two runners get DIFFERENT guarantees, on purpose, because their results mean different things.
#
# Prep and reply: quarantine an unparsable file, so the run reports as empty rather than decoding into
# silence. Nothing is invented in its place, because there is nothing honest to invent: an empty prep
# result would claim the run researched a show and found nobody, and a fabricated reply intent would
# drive a conversation state off a decision no model ever made.
for script in prep-run.sh reply-classify-run.sh; do
  assert_contains "${script} quarantines a results file that does not parse" \
    "$(cat "${RUNNERS_DIR}/${script}")" 'quarantine_unreadable_results'
done

# Scout gets the STRONGER one, and therefore not this one: it rewrites even a corrupt file into an honest
# per-source result (keeping the corrupt bytes), because its results are per-source and its ingest latches
# a content hash. Naming the sources it lost is both possible and load-bearing there; merely reporting
# "empty" would leave each source's health unjudged.
scout_body="$(cat "${RUNNERS_DIR}/scout-extract-run.sh")"
assert_contains "scout-extract reports every source the run never came back with" \
  "${scout_body}" 'ensure_every_queued_source_reported'
if [[ "${scout_body}" == *'quarantine_unreadable_results'* ]]; then
  echo "FAIL - scout must not merely quarantine: that would throw away its per-source not_read report"
  FAILURES=$((FAILURES + 1))
else
  echo "ok - scout keeps its stronger per-source guarantee rather than degrading to an empty run"
fi

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all results-guard.sh checks passed"
