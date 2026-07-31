#!/usr/bin/env bash
set -uo pipefail

# #1015: the scout-extract toolbar showed "0 of 20" through a run that was doing real work, because
# the model was asked to self-report progress by rewriting a separate file, and on 2026-07-16 it simply
# never did. A count is a fact about what the script handed out and what came back; asking the model to
# self-report it invites it to be confidently wrong about the one thing the record exists to establish
# (the same reasoning as record_model in models.sh). This derives the count itself, from the queue and
# results files the script already trusts, so the toolbar can never lie about progress no matter what
# the model does or forgets to do.

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

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/progress-watcher.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

QUEUE="${TMP}/queue.json"
RESULTS="${TMP}/results.json"
PROGRESS="${TMP}/progress.json"

field() {
  # Reads one top-level numeric field out of a progress.json for the assertions below.
  node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); console.log(j[process.argv[2]])' \
    "$1" "$2" 2>/dev/null
}

write_queue() {
  local n="$1"
  local items=""
  for ((i = 0; i < n; i++)); do
    items+="{\"sourceId\":\"s${i}\"}"
    [[ $i -lt $((n - 1)) ]] && items+=","
  done
  printf '{"version":2,"generatedAt":"2026-07-17T00:00:00Z","items":[%s]}' "${items}" > "${QUEUE}"
}

write_results() {
  local n="$1"
  local items=""
  for ((i = 0; i < n; i++)); do
    items+="{\"sourceId\":\"s${i}\",\"verdict\":\"upcoming_listings\",\"events\":[]}"
    [[ $i -lt $((n - 1)) ]] && items+=","
  done
  printf '{"version":1,"generatedAt":"2026-07-17T00:00:00Z","results":[%s]}' "${items}" > "${RESULTS}"
}

# --- the normal case: derives total and completed from what is actually on disk --------------------

write_queue 3
write_results 2
update_progress_from_results "${QUEUE}" "${RESULTS}" "${PROGRESS}"
assert_equals "total comes from the queue" "3" "$(field "${PROGRESS}" total)"
assert_equals "completed comes from the results actually written so far" "2" "$(field "${PROGRESS}" completed)"

# A later tick, after more sources land, moves the count forward with no model involvement at all.
write_results 3
update_progress_from_results "${QUEUE}" "${RESULTS}" "${PROGRESS}"
assert_equals "completed advances as the results file grows" "3" "$(field "${PROGRESS}" completed)"

# --- capped, never wrong-direction ------------------------------------------------------------------

# Should not happen (the run was only ever handed 3 sources), but a stray extra entry must never read
# as MORE than 100%.
write_results 5
update_progress_from_results "${QUEUE}" "${RESULTS}" "${PROGRESS}"
assert_equals "completed is capped at total, never over 100%" "3" "$(field "${PROGRESS}" completed)"

# --- degrades to leaving progress alone, never to zeroing it out or crashing ------------------------

write_queue 3
rm -f "${RESULTS}"
printf '{"version":1,"total":3,"completed":1}' > "${PROGRESS}"
update_progress_from_results "${QUEUE}" "${RESULTS}" "${PROGRESS}"
assert_equals "no results file yet: progress is left as it was, not zeroed" "1" "$(field "${PROGRESS}" completed)"

printf 'not json {' > "${RESULTS}"
printf '{"version":1,"total":3,"completed":1}' > "${PROGRESS}"
update_progress_from_results "${QUEUE}" "${RESULTS}" "${PROGRESS}"
assert_equals "an unparsable results file is left alone rather than read as zero" "1" "$(field "${PROGRESS}" completed)"

write_results 2
rm -f "${QUEUE}"
printf '{"version":1,"total":3,"completed":1}' > "${PROGRESS}"
update_progress_from_results "${QUEUE}" "${RESULTS}" "${PROGRESS}"
assert_equals "a missing queue means the total cannot be known, so progress is left alone" "1" "$(field "${PROGRESS}" completed)"

# --- #1023: the SAME function derives PREP's count, from PREP's own file shapes -------------------
#
# Prep switched to the identical script-derived progress as scout (#1023): its queue is `items[]` and
# its results are `results[]` of PrepResult objects keyed by naturalKey, the same two keys this function
# already folds through. So the ONE update_progress_from_results serves both runners, and this pins that
# a real prep-shaped pair derives correctly rather than trusting that "same keys" holds by inspection.
PREP_QUEUE="${TMP}/prep-queue.json"
PREP_RESULTS="${TMP}/prep-results.json"
PREP_PROGRESS="${TMP}/prep-progress.json"
printf '{"version":1,"generatedAt":"2026-07-17T00:00:00Z","items":[{"naturalKey":"a|2026-03-10|carnegie-hall"},{"naturalKey":"b|undated|none"},{"naturalKey":"c|2026-09-01|weill-recital-hall"}]}' > "${PREP_QUEUE}"
printf '{"version":1,"generatedAt":"2026-07-17T00:00:00Z","results":[{"naturalKey":"a|2026-03-10|carnegie-hall","contacts":[]}]}' > "${PREP_RESULTS}"
printf '{"version":1,"total":3,"completed":0}' > "${PREP_PROGRESS}"
update_progress_from_results "${PREP_QUEUE}" "${PREP_RESULTS}" "${PREP_PROGRESS}"
assert_equals "prep total comes from the prep queue's items" "3" "$(field "${PREP_PROGRESS}" total)"
assert_equals "prep completed counts the PrepResult entries written so far" "1" "$(field "${PREP_PROGRESS}" completed)"

# --- #1081: the SAME function derives REPLY-CLASSIFY's count, from its own file shapes -------------
#
# Reply-classify reached parity with prep and scout (#1081): its queue is `items[]` (one per replied
# recipient) and its results are `results[]` of v3 ReplyClassifyResult objects, the same two keys this
# function already folds through. So the ONE update_progress_from_results serves all three runners, and
# this pins that a real reply-classify-shaped pair derives correctly rather than trusting that "same
# keys" holds by inspection.
REPLY_QUEUE="${TMP}/reply-queue.json"
REPLY_RESULTS="${TMP}/reply-results.json"
REPLY_PROGRESS="${TMP}/reply-progress.json"
printf '{"version":3,"generatedAt":"2026-07-17T00:00:00Z","items":[{"naturalKey":"a|2026-03-10|carnegie-hall","recipientId":"pres@presentingorg.example"},{"naturalKey":"a|2026-03-10|carnegie-hall","recipientId":"act@aurorastrings.example"},{"naturalKey":"b|undated|none","recipientId":"info@lumendance.example"}]}' > "${REPLY_QUEUE}"
printf '{"version":3,"generatedAt":"2026-07-17T00:00:00Z","results":[{"naturalKey":"a|2026-03-10|carnegie-hall","recipientId":"pres@presentingorg.example","intent":"wants_to_book","draftSubject":"Re: x","draftBody":"y"}]}' > "${REPLY_RESULTS}"
printf '{"version":1,"total":3,"completed":0}' > "${REPLY_PROGRESS}"
update_progress_from_results "${REPLY_QUEUE}" "${REPLY_RESULTS}" "${REPLY_PROGRESS}"
assert_equals "reply-classify total comes from the reply queue's items" "3" "$(field "${REPLY_PROGRESS}" total)"
assert_equals "reply-classify completed counts the ReplyClassifyResult entries written so far" "1" "$(field "${REPLY_PROGRESS}" completed)"

# No node on PATH: this is a nice-to-have, never something that can fail the run or corrupt the file.
write_queue 3
write_results 2
printf '{"version":1,"total":3,"completed":1}' > "${PROGRESS}"
if PATH="/nonexistent" update_progress_from_results "${QUEUE}" "${RESULTS}" "${PROGRESS}"; then
  echo "ok - no node on PATH degrades quietly rather than failing the run"
else
  echo "FAIL - update_progress_from_results must not fail the run when node is unavailable"
  FAILURES=$((FAILURES + 1))
fi
assert_equals "and the progress file is left untouched without node" "1" "$(field "${PROGRESS}" completed)"

# #1597: a reachability check's queue no longer holds one item per show. A producer's shows collapse to
# ONE item that answers for the rest (alsoAnswersFor), so counting queue entries would tell Dan a check
# he started on six shows was "4 of 4" while two more were still landing. The total is the number of
# SHOWS the run will answer for, which is also exactly what the results file ends up holding.
cat > "${TMP}/grouped-queue.json" <<'EOF'
{"version":6,"generatedAt":"now","items":[
  {"naturalKey":"k1","alsoAnswersFor":["k1b","k1c"]},
  {"naturalKey":"k2"}
]}
EOF
cat > "${TMP}/grouped-results.json" <<'EOF'
{"version":6,"generatedAt":"now","results":[{"naturalKey":"k1"},{"naturalKey":"k1b"}]}
EOF
update_progress_from_results "${TMP}/grouped-queue.json" "${TMP}/grouped-results.json" "${TMP}/grouped-progress.json"
assert_equals "the total counts the shows a grouped queue answers for, not its item count" \
  "4" "$(field "${TMP}/grouped-progress.json" total)"
assert_equals "and completed still counts what has actually landed" \
  "2" "$(field "${TMP}/grouped-progress.json" completed)"

# All four home, and it reads as finished rather than capping at the old item count.
cat > "${TMP}/grouped-results.json" <<'EOF'
{"version":6,"generatedAt":"now","results":[{"naturalKey":"k1"},{"naturalKey":"k1b"},{"naturalKey":"k1c"},{"naturalKey":"k2"}]}
EOF
update_progress_from_results "${TMP}/grouped-queue.json" "${TMP}/grouped-results.json" "${TMP}/grouped-progress.json"
assert_equals "a fully answered grouped run reads as complete" \
  "4" "$(field "${TMP}/grouped-progress.json" completed)"

# #1804: the terse run. The runbook tells the run to write an entry per covered show, and nothing enforced
# it, so a run that answered a group of three with ONE entry sat at 1 of 3 for its whole life and never
# reached its own total. The app now credits that grouping when it settles, so the live count has to credit
# it identically or the two contradict each other about the same run.
cat > "${TMP}/terse-results.json" <<'EOF'
{"version":7,"generatedAt":"now","results":[
  {"naturalKey":"k1","contacts":[{"email":"jane@producer.example","confidence":"high"}]},
  {"naturalKey":"k2","contacts":[]}
]}
EOF
update_progress_from_results "${TMP}/grouped-queue.json" "${TMP}/terse-results.json" "${TMP}/terse-progress.json"
assert_equals "a terse run that answered a group with one entry reads as complete, like a compliant one" \
  "4" "$(field "${TMP}/terse-progress.json" completed)"

# The honest half, and the reason the credit is one-directional (Dan's call, 2026-07-31): a lead that came
# home having found NOBODY does not answer for its group. Those shows are genuinely still unanswered, and a
# count that credited them would report a run as complete while two of its shows had no answer at all.
cat > "${TMP}/empty-lead-results.json" <<'EOF'
{"version":7,"generatedAt":"now","results":[
  {"naturalKey":"k1","contacts":[],"emptyReason":"nothing_published"},
  {"naturalKey":"k2","contacts":[]}
]}
EOF
update_progress_from_results "${TMP}/grouped-queue.json" "${TMP}/empty-lead-results.json" "${TMP}/empty-progress.json"
assert_equals "a group lead that found nobody credits nothing to the shows it stood for" \
  "2" "$(field "${TMP}/empty-progress.json" completed)"

# A compliant run whose covered show came back with its OWN entry is counted once, not twice.
cat > "${TMP}/compliant-results.json" <<'EOF'
{"version":7,"generatedAt":"now","results":[
  {"naturalKey":"k1","contacts":[{"email":"jane@producer.example"}]},
  {"naturalKey":"k1b","contacts":[{"email":"jane@producer.example"}]}
]}
EOF
update_progress_from_results "${TMP}/grouped-queue.json" "${TMP}/compliant-results.json" "${TMP}/compliant-progress.json"
assert_equals "a covered show answered in its own right is never counted twice" \
  "3" "$(field "${TMP}/compliant-progress.json" completed)"

# An ungrouped queue (every normal Prep run, and every scout-extract run) is unchanged.
cat > "${TMP}/plain-queue.json" <<'EOF'
{"version":6,"generatedAt":"now","items":[{"naturalKey":"a"},{"naturalKey":"b"},{"naturalKey":"c"}]}
EOF
cat > "${TMP}/plain-results.json" <<'EOF'
{"version":6,"generatedAt":"now","results":[{"naturalKey":"a"}]}
EOF
update_progress_from_results "${TMP}/plain-queue.json" "${TMP}/plain-results.json" "${TMP}/plain-progress.json"
assert_equals "a queue with no grouping counts its items exactly as before" \
  "3" "$(field "${TMP}/plain-progress.json" total)"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all progress-watcher.sh checks passed"
