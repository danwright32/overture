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

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all progress-watcher.sh checks passed"
