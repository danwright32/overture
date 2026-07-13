#!/usr/bin/env bash
set -uo pipefail

# #847: the extract run read Dan's Kaufman Music Center page, extracted 20 events correctly, then
# noticed the listings were paginated and STOPPED TO ASK HIM which he wanted:
#
#   "I can fetch and extract the remaining pages now, or submit the first page and note in the results
#    that pagination wasn't checked. The choice affects completeness vs. speed."
#
# It then exited without writing the results file. Twenty successfully extracted shows, thrown away, and
# the app left polling for a file that would never arrive.
#
# This is a DETACHED run. There is nobody to ask. A question is not an output. The prompt is the only
# place that rule can live, so these checks hold it there.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

assert_contains() {
  local desc="$1" needle="$2"
  if [[ "${PROMPT}" == *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected the prompt to contain: ${needle}"
    FAILURES=$((FAILURES + 1))
  fi
}

PROMPT="$(cat "${SCRIPT_DIR}/scout-extract-run.sh")"

# The rule that would have saved the twenty shows: ALWAYS write the results file. There is no ending in
# which the right move is to stop and ask.
assert_contains "the run is told it must ALWAYS write results" "ALWAYS write"
assert_contains "the run is told never to stop and ask" "Never stop to ask"
assert_contains "an ambiguity is resolved by deciding, and the decision recorded" "decide"

# The `note` field already exists for exactly this. It is where a decision goes, so the run never has to
# choose between finishing and being honest about what it could not do.
assert_contains "the run is pointed at note as the place to record what it could not do" "note"

# Pagination specifically, because it is what actually happened and it will recur on any real venue's
# calendar. Whatever the rule is, it has to BE a rule, so the run never has to invent one mid-flight.
assert_contains "pagination has a stated rule" "paginat"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all scout-extract prompt checks passed"
