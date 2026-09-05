#!/usr/bin/env bash
set -euo pipefail

# Catches drift in doc/comment claims measured against Dan's live SwiftData store (#1063). Several
# files back a rule with a specific count taken from the live store AT WRITE TIME (docs/scout-extract-
# runbook.md, ExtractedEventGuard.swift, VenueDisplay.swift, and others this issue's own sweep found:
# ScoutService.swift, NativePathGuardTests.swift, docs/contracts.md, EventClassifier.swift,
# ScoutExtractContractTests.swift), and nothing re-verified the number as the store grew. #1060 found
# and fixed ONE instance (the runbook's "0 of 26 distinct venue strings contain a city" claim, stale
# since the store grew from 26 to 66 distinct venues) by accident, while working on an unrelated ticket.
# Three other copies of that exact claim survived untouched in docs/contracts.md, EventClassifier.swift,
# and ScoutExtractContractTests.swift, each still asserting "0 of 26" against a store that, as of this
# writing, has 66 distinct venues, 21 of them containing a comma.
#
# THE TAG CONVENTION: a single-line, greppable marker placed directly above (within a few lines of) a
# claim that cites a specific count measured against the live store:
#
#   LIVE-STORE-CLAIM verified=YYYY-MM-DD measure="what was counted, in a few words"
#
# embedded in whatever comment syntax the file uses (`// LIVE-STORE-CLAIM ...` in Swift, an HTML
# comment in Markdown). `verified` is the date a human last confirmed the claim is accurate (or, for a
# claim that is explicitly historical, i.e. "true on the day a change shipped" rather than an ongoing
# invariant, the date it was last reviewed as such). Optionally, when the SAME count can be recomputed
# from a file already checked into the repo (a fixture, not the live store), add:
#
#   LIVE-STORE-CLAIM verified=YYYY-MM-DD measure="..." fixture=path/to/file pattern="grep -E pattern" expect=N
#
# and this script recomputes `grep -cE pattern fixture` and fails the push if it disagrees with `expect`.
# That path is fully CI-safe (fixtures are checked in); the plain form is advisory only, since nothing
# in CI can re-run a query against a file that lives on Dan's Mac and nowhere else.
#
# THIS SCRIPT IS CI-SAFE BY CONSTRUCTION: it never opens, requires, or references the live store itself
# (~/Library/Application Support/Overture/Overture.store). It only reads tracked repository files. Advisory
# findings (a tag whose verified date has gone stale, an obviously-measured claim with no tag nearby) are
# reported but never fail the build, because staleness is expected to accumulate between someone
# actually re-checking the number against Dan's Mac; only a genuinely broken tag (malformed) or a
# checked-in fixture that disagrees with its own claim (a fully deterministic, CI-checkable fact) fails.
#
# The pure functions (extract_claims, find_untagged_claims, days_since, recompute_claim) are covered by
# check-live-store-claims.test.sh, which drives them against throwaway text so it runs anywhere,
# including CI, with no live-store or even real-file dependency at all.
#
# Usage: scripts/check-live-store-claims.sh [file ...]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# #3191: the shared per-machine stamp rules.
# shellcheck source=./lib/machine-stamp.sh
. "${SCRIPT_DIR}/lib/machine-stamp.sh"

# A verified date older than this many days is reported as stale (advisory, never a failure): the store
# has grown fast enough in this project (26 -> 66 distinct venues in about two weeks around #970/#1030)
# that a much longer threshold would let real drift sit for a long time before anyone is nudged to look.
STALE_THRESHOLD_DAYS=45

# Parses one line already known to contain the LIVE-STORE-CLAIM marker. On a well-formed tag, prints
# "verified<TAB>measure<TAB>fixture<TAB>pattern<TAB>expect" (the last three empty when absent). On a
# malformed one (a verified date not shaped YYYY-MM-DD, or an unterminated/missing measure="..."),
# prints "MALFORMED<TAB><the raw line>" so the caller can report it without silently dropping it.
parse_claim_tag() {
  local line="$1"
  if [[ "${line}" =~ LIVE-STORE-CLAIM[[:space:]]+verified=([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]+measure=\"([^\"]*)\" ]]; then
    local verified="${BASH_REMATCH[1]}"
    local measure="${BASH_REMATCH[2]}"
    local fixture="" pattern="" expect=""
    if [[ "${line}" =~ fixture=([^[:space:]]+) ]]; then fixture="${BASH_REMATCH[1]}"; fi
    if [[ "${line}" =~ pattern=\"([^\"]*)\" ]]; then pattern="${BASH_REMATCH[1]}"; fi
    if [[ "${line}" =~ expect=([0-9]+) ]]; then expect="${BASH_REMATCH[1]}"; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "${verified}" "${measure}" "${fixture}" "${pattern}" "${expect}"
  else
    printf 'MALFORMED\t%s\n' "${line}"
  fi
}

# Given file text ($1), finds every line carrying a LIVE-STORE-CLAIM tag and prints one row per tag:
# "lineno<TAB>verified<TAB>measure<TAB>fixture<TAB>pattern<TAB>expect", or "lineno<TAB>MALFORMED<TAB><raw
# line>" for a tag that didn't parse. Pure: takes text, touches no files, so the test drives it with
# throwaway content standing in for a real source file.
extract_claims() {
  local text="$1"
  local line lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    if [[ "${line}" == *"LIVE-STORE-CLAIM"* ]]; then
      printf '%s\t%s\n' "${lineno}" "$(parse_claim_tag "${line}")"
    fi
  done <<< "${text}"
}

# Given file text ($1), finds lines that look like an un-tagged live-store-measured claim: they mention
# "live store" or "live rows" AND carry a digit (the "0 of 26 distinct venue strings contain a city" and
# "0 of 132 live rows had a missing... venue" shapes both occur verbatim in this repo) with no
# LIVE-STORE-CLAIM tag within 6 lines above (a doc-comment block routinely wraps the tag a line or two
# above the sentence it covers). Prints "lineno<TAB><the line>" for each miss. Deliberately requires BOTH
# signals on the same line: "live store"/"live rows" alone (a mention with no count, e.g. "this runs
# against the live store") is common and must not false-alarm.
find_untagged_claims() {
  local text="$1"
  local line lineno=0
  local -a claim_lines=()

  while IFS= read -r line; do
    lineno=$((lineno + 1))
    if [[ "${line}" == *"LIVE-STORE-CLAIM"* ]]; then
      claim_lines+=("${lineno}")
    fi
  done <<< "${text}"

  lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    if [[ "${line}" =~ [Ll]ive[[:space:]](store|rows) ]] && [[ "${line}" =~ [0-9] ]]; then
      local covered=0 tl
      for tl in "${claim_lines[@]:-}"; do
        [[ -z "${tl}" ]] && continue
        if (( tl <= lineno && lineno - tl <= 6 )); then
          covered=1
          break
        fi
      done
      if [[ "${covered}" -eq 0 ]]; then
        printf '%s\t%s\n' "${lineno}" "${line}"
      fi
    fi
  done <<< "${text}"
}

# claim_candidates FILE... : the subset of those files that could possibly carry a claim.
#
# #3237: this scan cost 46 seconds of the cheap lane, and almost all of it was reading files that say
# nothing. It forked a `cat` and ran two whole-text bash loops for every one of the ~1,500 tracked Swift
# and Markdown files, and this repo's macOS bash is 3.2, where that is slow.
#
# Both parsers can only ever emit for a line holding `LIVE-STORE-CLAIM`, or `live store` / `live rows`.
# So a file with none of those produces nothing however carefully it is read, and one `grep -l` over the
# whole list replaces ~1,500 forks with one.
#
# DELIBERATELY LOOSER than the parsers. `find_untagged_claims` also requires a digit on the same line,
# and this filter does not ask for one: reproducing the parsers' exact conditions here would be a second
# definition of the rule, free to drift against the first in the direction that hides a finding (L107).
# Being a superset is the only property that matters, and it is what the fixture asserts.
claim_candidates() {
  [[ "$#" -gt 0 ]] || return 0
  local out status=0
  out="$(grep -lE 'LIVE-STORE-CLAIM|[Ll]ive[[:space:]](store|rows)' -- "$@" 2>/dev/null)" || status=$?
  # grep exits 1 for "matched nothing", which is a real answer, and >1 for an ERROR, which is not. A
  # failed grep coming back as an empty list would empty the corpus and the summary would then report
  # zero claims, which is exactly what a tree with no claims reports (L98).
  if [[ "${status}" -gt 1 ]]; then
    echo "check-live-store-claims: could not read the file list (grep exit ${status}); refusing to" >&2
    echo "  report on a corpus it could not narrow." >&2
    return 2
  fi
  printf '%s\n' "${out}"
  return 0
}

# #3191: through the shared helper. This was the THIRD copy of the arithmetic and the only one that had
# lost its refusal: it neither suppressed `date`'s error nor returned early, so an unreadable date
# reached the subtraction and the caller got a number nobody measured (L11). It answers nothing now, the
# way the other two always did.
days_since() {
  machine_stamp_days_since "$1" "$2"
}


# Given a checked-in fixture's text ($1), a grep -E pattern ($2), and the count the claim asserts ($3),
# recomputes the real count and reports "OK" when it matches or "MISMATCH<TAB><actual>" when it doesn't.
# This is the ONLY recompute path the check performs: it never touches the live store, only a file
# already tracked in the repo, so it is fully deterministic and CI-safe to fail on.
recompute_claim() {
  local fixture_text="$1" pattern="$2" expected="$3"
  local actual
  actual="$(printf '%s\n' "${fixture_text}" | grep -cE "${pattern}" || true)"
  if [[ "${actual}" -eq "${expected}" ]]; then
    echo "OK"
  else
    printf 'MISMATCH\t%s\n' "${actual}"
  fi
}

main() {
  cd "${REPO_ROOT}"
  local today
  today="$(date +%Y-%m-%d)"

  local files=("$@") swept=0
  if [[ "${#files[@]}" -eq 0 ]]; then
    swept=1
    local file_list
    file_list="$(git ls-files '*.swift' '*.md')"
    while IFS= read -r f; do
      files+=("${f}")
    done <<< "${file_list}"
  fi

  # #3237: read only the files that could carry a claim. Equivalent by construction, since the parsers
  # emit nothing for the rest, and it is what takes this from 46 seconds to about a second.
  local candidate_list candidate_status=0
  candidate_list="$(claim_candidates "${files[@]}")" || candidate_status=$?
  if [[ "${candidate_status}" -ne 0 ]]; then
    exit 2
  fi
  local narrowed=()
  while IFS= read -r f; do
    [[ -n "${f}" ]] && narrowed+=("${f}")
  done <<< "${candidate_list}"

  # A SWEEP that narrows to nothing is unmeasured, never clean: this repository holds 152 tagged claims,
  # so an empty result means the filter is broken rather than that the tree is (L98). A run given
  # explicit files is different: a test legitimately hands it a file with no claims in it.
  if [[ "${swept}" -eq 1 && "${#narrowed[@]}" -eq 0 ]]; then
    echo "check-live-store-claims: the sweep narrowed ${#files[@]} tracked files to none, which is a" >&2
    echo "  broken filter rather than a tree with no claims. Nothing was examined." >&2
    exit 2
  fi
  files=("${narrowed[@]+"${narrowed[@]}"}")

  local total_claims=0 malformed=0 stale=0 mismatches=0 untagged=0
  local report=""

  # Deliberately NOT `done < <(extract_claims "${text}")` (process substitution) here: this loop runs
  # once per file across hundreds of tracked files, and this repo's macOS system bash is 3.2 (no
  # mapfile; `/usr/bin/env bash` resolves to it), whose process substitution is known to race and drop
  # output silently when reused this many times in one script run. That is not hypothetical: it is what
  # first made this script miss real, un-tagged claims (ScoutService.swift, NativePathGuardTests.swift)
  # nondeterministically while running clean when the same files were passed explicitly. Capturing each
  # helper's output into a plain variable first, then reading it back with a here-string, has no
  # subshell/FIFO timing to race and reproduced zero misses across repeated runs.
  local f
  for f in "${files[@]}"; do
    [[ -f "${f}" ]] || continue
    local text
    text="$(cat "${f}")"

    local claims_out untagged_out row lineno rest verified measure fixture pattern expect
    claims_out="$(extract_claims "${text}")"
    while IFS= read -r row; do
      [[ -z "${row}" ]] && continue
      lineno="${row%%$'\t'*}"
      rest="${row#*$'\t'}"
      if [[ "${rest}" == MALFORMED$'\t'* ]]; then
        report+="MALFORMED  ${f}:${lineno}  ${rest#MALFORMED$'\t'}"$'\n'
        malformed=$((malformed + 1))
        continue
      fi
      IFS=$'\t' read -r verified measure fixture pattern expect <<< "${rest}"
      total_claims=$((total_claims + 1))
      local age staleness="OK"
      age="$(days_since "${verified}" "${today}")"
      if [[ "${age}" -ge "${STALE_THRESHOLD_DAYS}" ]]; then
        staleness="STALE (${age}d, advisory)"
        stale=$((stale + 1))
      fi
      report+="CLAIM  ${f}:${lineno}  verified=${verified} [${staleness}]  measure=\"${measure}\""$'\n'

      if [[ -n "${fixture}" ]]; then
        if [[ ! -f "${REPO_ROOT}/${fixture}" ]]; then
          report+="  ERROR: fixture not found at ${fixture}"$'\n'
          mismatches=$((mismatches + 1))
        else
          local result actual
          result="$(recompute_claim "$(cat "${REPO_ROOT}/${fixture}")" "${pattern}" "${expect}")"
          if [[ "${result}" == "OK" ]]; then
            report+="  recomputed against ${fixture}: matches (expect ${expect})"$'\n'
          else
            actual="${result#MISMATCH$'\t'}"
            report+="  MISMATCH: ${fixture} recomputes to ${actual}, claim says ${expect}"$'\n'
            mismatches=$((mismatches + 1))
          fi
        fi
      fi
    done <<< "${claims_out}"

    untagged_out="$(find_untagged_claims "${text}")"
    while IFS= read -r row; do
      [[ -z "${row}" ]] && continue
      lineno="${row%%$'\t'*}"
      rest="${row#*$'\t'}"
      report+="UNTAGGED?  ${f}:${lineno}  ${rest}"$'\n'
      untagged=$((untagged + 1))
    done <<< "${untagged_out}"
  done

  if [[ -n "${report}" ]]; then
    printf '%s' "${report}"
  fi
  echo "Summary: ${total_claims} tagged live-store claim(s), ${malformed} malformed, ${stale} stale" \
       "(advisory, >${STALE_THRESHOLD_DAYS}d), ${mismatches} fixture mismatch(es)," \
       "${untagged} untagged signal(s) (advisory)."

  if [[ "${malformed}" -gt 0 ]]; then
    echo
    echo "A LIVE-STORE-CLAIM tag above did not parse. Fix its shape:"
    echo '  LIVE-STORE-CLAIM verified=YYYY-MM-DD measure="what was counted"'
    exit 1
  fi
  if [[ "${mismatches}" -gt 0 ]]; then
    echo
    echo "A claim's fixture= no longer matches its own expect=. Recompute the real count and update the"
    echo "claim (or the tag), the same way #1060 fixed the runbook's stale '0 of 26' venue-string count."
    exit 1
  fi

  exit 0
}

# Sourceable without running (the test sources this to drive extract_claims, find_untagged_claims,
# days_since and recompute_claim directly). Mirrors check-brand-voice-drift.sh's convention.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
