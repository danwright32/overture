#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/shell-assertions.sh"

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

# --- #3237: the sweep reads only the files that can hold a claim ---------------------------------------
# The scan cost 46 seconds of the cheap lane, because it forked a `cat` and ran two whole-text bash loops
# for every one of the ~1,500 tracked Swift and Markdown files. Both parsers can only ever emit for a line
# holding `LIVE-STORE-CLAIM`, or `live store`/`live rows` beside a digit, so a file with none of those
# produces nothing however carefully it is read.
#
# `claim_candidates` is that pre-filter. What has to be true of it is that it is a SUPERSET of what the
# parsers can act on: a file it drops must be one they would have said nothing about.
CAND_DIR="$(fixture_scratch_dir)"
# Removed here: the runner checks the temp directory the moment this fixture ends, and no other EXIT trap
# is installed in this file, which is the thing to check before adding one.
trap 'rm -rf "${CAND_DIR}" "${SWEEP_REPO:-}"' EXIT
printf 'let x = 1\n' > "${CAND_DIR}/plain.swift"
printf '// LIVE-STORE-CLAIM verified=2026-01-01 measure="rows"\n' > "${CAND_DIR}/tagged.swift"
printf '// 0 of 26 live rows carry a city\n' > "${CAND_DIR}/untagged.swift"
printf '// this runs against the live store\n' > "${CAND_DIR}/mention.swift"

CANDIDATES="$(claim_candidates "${CAND_DIR}/plain.swift" "${CAND_DIR}/tagged.swift" \
  "${CAND_DIR}/untagged.swift" "${CAND_DIR}/mention.swift")"
assert_contains "a tagged file is a candidate" "${CANDIDATES}" "tagged.swift"
assert_contains "an untagged live-rows claim is a candidate" "${CANDIDATES}" "untagged.swift"
# A bare mention with no digit cannot produce a finding, but it IS kept: the filter is deliberately
# looser than the parsers, because a filter that had to reproduce their exact conditions would be a
# second definition of the rule, drifting silently against the first (L107).
assert_contains "a bare mention of the live store is kept too" "${CANDIDATES}" "mention.swift"
assert_not_contains "a file with none of the signals is dropped" "${CANDIDATES}" "plain.swift"

# Zero candidates out of a NON-EMPTY file list is UNMEASURED, not clean. This is the whole risk of the
# change: a broken filter empties the corpus and the summary then reports 0 claims, which is what a tree
# with no claims in it reports (L98). The tree really holds 152.
# A grep that ERRORED is not a grep that matched nothing, and the two are one character apart in the
# status. Driven with a path grep cannot read, which is what an unreadable tree looks like from here.
CAND_ERR="$(claim_candidates "${CAND_DIR}/tagged.swift" "${CAND_DIR}/no-such-file-at-all.swift" 2>&1)"
CAND_ERR_STATUS=$?
assert_eq "a grep that could not read its files refuses" "2" "${CAND_ERR_STATUS}"
assert_contains "and says it will not report on a corpus it could not narrow" \
  "${CAND_ERR}" "refusing to"

# The other direction, so the refusal is not one that fires on every run: matching NOTHING is a real
# answer and comes back clean.
claim_candidates "${CAND_DIR}/plain.swift" >/dev/null 2>&1
assert_eq "a file list that simply holds no claim is not an error" "0" "$?"

# A SWEEP that narrows to nothing is unmeasured, never clean, and this is the whole risk of the change:
# a broken filter empties the corpus and the summary then reports 0 claims, which is exactly what a tree
# with no claims reports (L98). Driven end to end, in a throwaway repository, because the script takes
# its root from its OWN location: copied into `<tmp>/scripts/`, its root is `<tmp>`.
SWEEP_REPO="$(fixture_scratch_dir)"
mkdir -p "${SWEEP_REPO}/scripts"
cp "${REPO_ROOT}/scripts/check-live-store-claims.sh" "${SWEEP_REPO}/scripts/"
printf 'let x = 1\n' > "${SWEEP_REPO}/nothing.swift"
( cd "${SWEEP_REPO}" && git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -qm t ) >/dev/null 2>&1
SWEEP_OUT="$( cd "${SWEEP_REPO}" && ./scripts/check-live-store-claims.sh 2>&1 )"
SWEEP_STATUS=$?
assert_eq "a sweep that narrows to nothing refuses" "2" "${SWEEP_STATUS}"
assert_contains "and says nothing was examined rather than that all is well" \
  "${SWEEP_OUT}" "Nothing was examined"
assert_not_contains "and never prints a clean summary" "${SWEEP_OUT}" "0 tagged live-store claim(s), 0 malformed"

# The other direction in the same repository, so the refusal is about an empty CORPUS and not about a
# small one: one file carrying a claim is enough to make it report normally.
printf '// LIVE-STORE-CLAIM verified=2026-01-01 measure="rows"\n' > "${SWEEP_REPO}/claim.swift"
( cd "${SWEEP_REPO}" && git add -A && git -c user.email=t@t -c user.name=t commit -qm t2 ) >/dev/null 2>&1
SWEEP_OK="$( cd "${SWEEP_REPO}" && ./scripts/check-live-store-claims.sh 2>&1 )"
assert_contains "a sweep that finds one claim reports it rather than refusing" "${SWEEP_OK}" "1 tagged live-store claim(s)"

ALL_FILES="$(cd "${REPO_ROOT}" && git ls-files '*.swift' '*.md')"
COUNT=0
while IFS= read -r f; do [[ -n "${f}" ]] && COUNT=$((COUNT + 1)); done <<< "${ALL_FILES}"
assert_eq "the tree really has files to scan" "true" "$([[ "${COUNT}" -gt 1000 ]] && echo true || echo false)"

NARROWED=0
while IFS= read -r f; do [[ -n "${f}" ]] && NARROWED=$((NARROWED + 1)); done <<< "$(cd "${REPO_ROOT}" && claim_candidates ${ALL_FILES})"
assert_eq "and the filter keeps a plausible fraction of them, rather than none" "true" \
  "$([[ "${NARROWED}" -gt 20 && "${NARROWED}" -lt "${COUNT}" ]] && echo true || echo false)"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "check-live-store-claims.test.sh: all assertions passed"
  exit 0
else
  echo "check-live-store-claims.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
