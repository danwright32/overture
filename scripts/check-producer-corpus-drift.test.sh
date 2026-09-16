#!/usr/bin/env bash
# The JUDGING half of scripts/check-producer-corpus-drift.sh (#2680), driven through its feed seam so
# every outcome is exercised on every push without a single request reaching the venue.
#
# The script itself is opt in because it fetches. This is not: a check nobody runs is a check that stops
# working silently, and what can be proved cheaply is everything except the fetch.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/shell-assertions.sh
. "${SCRIPT_DIR}/lib/shell-assertions.sh"

FAILURES=0
CHECK="${SCRIPT_DIR}/check-producer-corpus-drift.sh"
WORK="$(fixture_scratch_dir producer-drift-fixture)"
trap 'rm -rf "${WORK}"' EXIT

# A feed body in the shape the live one arrives in: an array of events, each with a superTitle.
write_feed() {
  local out="$1"; shift
  {
    printf '['
    local first=1
    for title in "$@"; do
      [ "${first}" -eq 1 ] || printf ','
      first=0
      printf '{"title":"An evening","superTitle":"%s","dateTime":1786000000000}' "${title}"
    done
    printf ']'
  } > "${out}"
}

write_corpus() {
  local out="$1"; shift
  {
    printf '{"source":"fixture","fetchedAt":"2026-08-13","superTitles":['
    local first=1
    for title in "$@"; do
      [ "${first}" -eq 1 ] || printf ','
      first=0
      printf '"%s"' "${title}"
    done
    printf ']}'
  } > "${out}"
}

run_check() {
  OVERTURE_VENUETIX_FEED_FILE="$1" OVERTURE_SUPERTITLE_FIXTURE="$2" "${CHECK}" 2>&1
}

# --- 0: in step -----------------------------------------------------------------------------------
write_feed "${WORK}/same-feed.json" "Track 29 Productions" "A New Musical Concept"
write_corpus "${WORK}/same-corpus.json" "Track 29 Productions" "A New Musical Concept"
OUT="$(run_check "${WORK}/same-feed.json" "${WORK}/same-corpus.json")"
STATUS=$?
assert_equals "a feed matching the committed corpus is IN STEP" "0" "${STATUS}"
assert_contains "and says so" "${OUT}" "IN STEP"
# The rule was really applied to both sides, rather than the comparison passing over two empty lists.
assert_contains "and reports what the rule accepted on each side" "${OUT}" "1 the rule calls a producer"

# --- 1: drifted, and the boundary moved -----------------------------------------------------------
write_feed "${WORK}/moved-feed.json" "Track 29 Productions" "A New Musical Concept" \
  "Produced by Mackenzie Bruen"
write_corpus "${WORK}/moved-corpus.json" "Track 29 Productions" "A New Musical Concept"
OUT="$(run_check "${WORK}/moved-feed.json" "${WORK}/moved-corpus.json")"
STATUS=$?
assert_equals "a supertitle the rule accepts, absent from the corpus, is DRIFT" "1" "${STATUS}"
assert_contains "it says the boundary moved" "${OUT}" "THE BOUNDARY MOVED"
assert_contains "and names the arrival" "${OUT}" "+ Produced by Mackenzie Bruen"
assert_contains "and counts it as arrived" "${OUT}" "arrived since the corpus was taken: 1"

# --- 1: drifted with the boundary UNMOVED, which is the ordinary week --------------------------------
write_feed "${WORK}/churn-feed.json" "Track 29 Productions" "A Brand New Marketing Line"
write_corpus "${WORK}/churn-corpus.json" "Track 29 Productions" "A New Musical Concept"
OUT="$(run_check "${WORK}/churn-feed.json" "${WORK}/churn-corpus.json")"
STATUS=$?
assert_equals "ordinary churn is still reported as drift" "1" "${STATUS}"
assert_contains "one arrived" "${OUT}" "arrived since the corpus was taken: 1"
assert_contains "one gone" "${OUT}" "gone since the corpus was taken:    1"
assert_not_contains "and the boundary did not move, so it does not say it did" "${OUT}" "THE BOUNDARY MOVED"

# --- 1: it NEVER rewrites the fixture --------------------------------------------------------------
write_feed "${WORK}/rw-feed.json" "Produced by Mackenzie Bruen"
write_corpus "${WORK}/rw-corpus.json" "Track 29 Productions"
BEFORE="$(cat "${WORK}/rw-corpus.json")"
run_check "${WORK}/rw-feed.json" "${WORK}/rw-corpus.json" > /dev/null
assert_equals "the committed corpus is untouched, so a new one is always a change somebody read" \
  "${BEFORE}" "$(cat "${WORK}/rw-corpus.json")"

# --- 2: unmeasured, four ways, each named --------------------------------------------------------
OUT="$(run_check "${WORK}/no-such-feed.json" "${WORK}/same-corpus.json")"
STATUS=$?
assert_equals "a feed that is not there is UNMEASURED, not in step" "2" "${STATUS}"
assert_contains "and says which" "${OUT}" "does not exist"

printf 'not json at all' > "${WORK}/garbage.json"
OUT="$(run_check "${WORK}/garbage.json" "${WORK}/same-corpus.json")"
STATUS=$?
assert_equals "a feed that will not parse is UNMEASURED" "2" "${STATUS}"
assert_contains "and reads it as a possible feed shape change" "${OUT}" "feed shape change"

printf '[]' > "${WORK}/empty.json"
OUT="$(run_check "${WORK}/empty.json" "${WORK}/same-corpus.json")"
STATUS=$?
assert_equals "an EMPTY feed is UNMEASURED rather than a clean comparison" "2" "${STATUS}"

# A feed carrying EVENTS and no supertitle at all, which is a different failure from an empty array and
# has to be kept apart from it: it is what a renamed `superTitle` field looks like, and it would
# otherwise sail through as "every committed supertitle has vanished", which reads as a real finding
# about the venue rather than about the feed (L98, L11).
printf '[{"title":"An evening","dateTime":1786000000000}]' > "${WORK}/no-supertitles.json"
OUT="$(run_check "${WORK}/no-supertitles.json" "${WORK}/same-corpus.json")"
STATUS=$?
assert_equals "a feed of events carrying no supertitle at all is UNMEASURED" "2" "${STATUS}"
assert_contains "and says there was nothing to compare" "${OUT}" "nothing to compare"

write_feed "${WORK}/ok-feed.json" "Track 29 Productions"
OUT="$(run_check "${WORK}/ok-feed.json" "${WORK}/no-such-corpus.json")"
STATUS=$?
assert_equals "a missing committed corpus is UNMEASURED" "2" "${STATUS}"
assert_contains "and says which half was missing" "${OUT}" "is not there"

# The rule source itself, which is the half that would otherwise fail quietly: with nothing to judge
# with, every supertitle reads as refused and the boundary looks perfectly stable.
OUT="$(OVERTURE_PRODUCER_RULE_SOURCE="${WORK}/no-such-rule.swift" \
  OVERTURE_VENUETIX_FEED_FILE="${WORK}/ok-feed.json" \
  OVERTURE_SUPERTITLE_FIXTURE="${WORK}/same-corpus.json" "${CHECK}" 2>&1)"
STATUS=$?
assert_equals "no producer rule to judge with is UNMEASURED" "2" "${STATUS}"

if [ "${FAILURES}" -eq 0 ]; then
  echo "All check-producer-corpus-drift.sh fixtures passed."
else
  echo "${FAILURES} check-producer-corpus-drift.sh assertion(s) failed."
  exit 1
fi
