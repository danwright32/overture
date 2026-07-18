#!/usr/bin/env bash
set -uo pipefail

# Pure-function coverage for check-live-store-claims.sh (#1063). The real check greps every tracked
# Swift/Markdown file for the LIVE-STORE-CLAIM tag (docs/scout-extract-runbook.md, ExtractedEventGuard.swift,
# VenueDisplay.swift, and others #1063's own sweep found), which is why it can't be driven against the real
# repo here without becoming a moving target: this fixture drives the pure parsing/staleness/recompute
# functions against throwaway text instead, so it runs anywhere including CI, with no live-store dependency
# at all.
#
# The load-bearing cases are `red_malformed` and `red_untagged`: a malformed tag (bad date shape, an
# unterminated measure) and an obviously-measured, un-tagged claim ("on the live store, 0 of 40 ...") are
# exactly the two shapes #1063 exists to catch before they sit unnoticed the way the "0 of 26" claim did
# across three files. If the detector stops flagging either, this fixture goes red.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./check-live-store-claims.sh
source "${SCRIPT_DIR}/check-live-store-claims.sh"
# check-live-store-claims.sh's own `set -euo pipefail` is now active in this shell too. Turn errexit
# off so one failing assertion doesn't abort the rest of the run.
set +e

FAILURES=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
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
    echo "  actual: ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_empty() {
  local desc="$1" actual="$2"
  if [[ -z "${actual}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected empty, got: ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

# --- extract_claims: a well-formed tag parses cleanly -----------------------------------------------

GREEN_TAG='
// LIVE-STORE-CLAIM verified=2026-07-18 measure="distinct location values in the live store"
// Measured against the live store'"'"'s 11 distinct `location` values: rejects every street-address
'
OUT="$(extract_claims "${GREEN_TAG}")"
IFS=$'\t' read -r lineno verified measure fixture pattern expect <<< "${OUT}"
assert_eq "green tag: found on line 2" "2" "${lineno}"
assert_eq "green tag: verified date parsed" "2026-07-18" "${verified}"
assert_eq "green tag: measure text parsed" "distinct location values in the live store" "${measure}"
assert_empty "green tag: no fixture attribute" "${fixture}"

# --- extract_claims: a malformed tag (bad date shape) is flagged, not silently dropped ---------------

RED_MALFORMED='
// LIVE-STORE-CLAIM verified=07-18-2026 measure="distinct venues with a comma"
'
OUT="$(extract_claims "${RED_MALFORMED}")"
assert_contains "malformed tag: flagged as MALFORMED" "${OUT}" "MALFORMED"
assert_contains "malformed tag: raw line kept for the report" "${OUT}" "07-18-2026"

RED_UNTERMINATED='
// LIVE-STORE-CLAIM verified=2026-07-18 measure="distinct venues with a comma
'
OUT="$(extract_claims "${RED_UNTERMINATED}")"
assert_contains "unterminated measure: flagged as MALFORMED" "${OUT}" "MALFORMED"

# --- find_untagged_claims: an obviously-measured claim with no nearby tag is caught -------------------

RED_UNTAGGED='
// The venue cannot answer it. On the live store, 0 of 40 distinct venue strings contain a city.
'
OUT="$(find_untagged_claims "${RED_UNTAGGED}")"
assert_contains "untagged: line number recorded" "${OUT}" $'\t'
assert_contains "untagged: snippet carries the claim text" "${OUT}" "0 of 40 distinct venue strings"

# A tag placed within the 6-line window above the claim covers it (no false positive).
GREEN_COVERED='
// LIVE-STORE-CLAIM verified=2026-07-18 measure="distinct venue strings containing a city"
// The venue cannot answer it. On the live store, 0 of 40 distinct venue strings contain a city.
'
OUT="$(find_untagged_claims "${GREEN_COVERED}")"
assert_empty "covered: a tagged claim is not reported as untagged" "${OUT}"

# A mention of "the live store" with no digit on the line is not a claim at all (avoid false alarms on
# ordinary prose, e.g. "the live store" mentioned without any measured count).
GREEN_NO_DIGIT='
// This runs against the live store, never a fixture, so treat it with care.
'
OUT="$(find_untagged_claims "${GREEN_NO_DIGIT}")"
assert_empty "no digit: plain live-store prose is not flagged" "${OUT}"

# "live rows" (not "live store") is the exact phrasing #1063's real sweep found in
# ExtractedEventGuard.swift/ScoutService.swift/NativePathGuardTests.swift ("0 of 132 live rows had a
# missing..."), so the detector must catch that phrase too, not only "live store".
RED_LIVE_ROWS='
// Carnegie always names a hall (0 of 132 live rows had a missing, placeholder, or numeric-id venue).
'
OUT="$(find_untagged_claims "${RED_LIVE_ROWS}")"
assert_contains "live rows: caught even without the word store" "${OUT}" "0 of 132 live rows"

# --- days_since: pure date arithmetic -----------------------------------------------------------------

assert_eq "days_since: same day is 0" "0" "$(days_since 2026-07-18 2026-07-18)"
assert_eq "days_since: two days ago is 2" "2" "$(days_since 2026-07-16 2026-07-18)"
assert_eq "days_since: sixty days ago is 60" "60" "$(days_since 2026-05-19 2026-07-18)"

# --- recompute_claim: a claim backed by a checked-in fixture is recomputed, not trusted ----------------

FIXTURE_TEXT='alpha, Manhattan
beta, Brooklyn
gamma
delta, Queens'

# 3 of 4 lines contain a comma: a claim of "expect=3" matches the fixture.
OUT="$(recompute_claim "${FIXTURE_TEXT}" "," 3)"
assert_eq "recompute: matching count reports OK" "OK" "${OUT}"

# The load-bearing recompute case: a claim of "expect=0" is wrong given the same fixture (3 lines have a
# comma), and the mismatch must be reported with the real count, not silently accepted.
OUT="$(recompute_claim "${FIXTURE_TEXT}" "," 0)"
assert_contains "recompute: a wrong claim is flagged as MISMATCH" "${OUT}" "MISMATCH"
assert_contains "recompute: the actual recomputed count is reported" "${OUT}" "3"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "check-live-store-claims.test.sh: all assertions passed"
  exit 0
else
  echo "check-live-store-claims.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
