#!/usr/bin/env bash
set -uo pipefail

# #2366: the pure halves of scripts/check-far-future-fixtures.sh, driven without paying for two suite
# runs.
#
# The defect it exists for: a fixture dated 2099 was chosen to mean "always upcoming", and once a rule
# bounded the future (#2359's triage window) it also came to mean "always OUTSIDE the window", so any
# assertion about that window went on passing while covering nothing. Measured 2026-08-09, 55 tests use
# 2099-09-19 alone, across at least twelve files, and nobody can tell which of them still assert
# anything.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${SCRIPT_DIR}/check-far-future-fixtures.sh"
FAILURES=0

WORK="$(mktemp -d)"
MAIN_SHELL_PID="${BASHPID:-$$}"
trap '[ "${BASHPID:-$$}" = "${MAIN_SHELL_PID}" ] && rm -rf "${WORK}"' EXIT

# Sourceable without running, the same shape check-fixtures-do-not-age.sh uses.
# shellcheck disable=SC1090
source "${CHECK}"

# --- which dates are beyond the horizon ---------------------------------------------------------------
# The horizon is derived from the year the run happens in, never written down: a literal cutoff is a
# date fixture of its own and ages exactly like the ones this check exists to find (L130).
assert_equals "2099 is beyond the horizon in 2026" "1" "$(is_far_future 2099 2026 && echo 1 || echo 0)"
assert_equals "a show three years out is beyond it" "1" "$(is_far_future 2029 2026 && echo 1 || echo 0)"
assert_equals "next year is not" "0" "$(is_far_future 2027 2026 && echo 1 || echo 0)"
assert_equals "this year is not" "0" "$(is_far_future 2026 2026 && echo 1 || echo 0)"
assert_equals "the past is not: a date behind the clock is #2669's question, not this one" \
  "0" "$(is_far_future 2020 2026 && echo 1 || echo 0)"

# --- the shift brings a far-future fixture near, and leaves everything else alone ---------------------
# Only the far-future literals move. Shifting the whole file (which is #2669's rule, and right for its
# question) would drag a same-file 2026 date to 1953 and break a pair the fixture depends on, and the
# resulting failure would be this check's own doing rather than a finding (L130).
IN="${WORK}/in.swift"
cat > "${IN}" <<'SWIFT'
let show = "2099-09-19"
let booking = "2026-08-14"
let stamp = "2099-10-01T19:30:00Z"
SWIFT
OUT="$(pull_far_future_dates_near 2026 < "${IN}")"
assert_contains "the far-future show lands inside the coming year" "${OUT}" '"2026-09-19"'
assert_contains "a second far-future date moves by the SAME amount, so their gap survives" \
  "${OUT}" '"2026-10-01T19:30:00Z"'
assert_contains "a date that was already near is untouched" "${OUT}" '"2026-08-14"'

# The gap between the two far-future dates is preserved, which is the whole reason they move together.
assert_equals "the two moved dates keep their twelve day gap" "1" \
  "$(printf '%s' "${OUT}" | grep -c '2026-09-19')"

# --- a file that MIXES the two is reported rather than silently half shifted --------------------------
# This is the one case the shift genuinely changes a relationship rather than a distance, so it is named
# for a person to read rather than folded in (L11).
assert_equals "a file holding both kinds of date is flagged as mixed" "1" \
  "$(mixes_far_and_near < "${IN}" && echo 1 || echo 0)"
NEAR_ONLY="${WORK}/near.swift"
printf 'let a = "2026-08-14"\n' > "${NEAR_ONLY}"
assert_equals "a file with no far-future date is not mixed" "0" \
  "$(mixes_far_and_near < "${NEAR_ONLY}" && echo 1 || echo 0)"
FAR_ONLY="${WORK}/far.swift"
printf 'let a = "2099-09-19"\nlet b = "2099-10-01"\n' > "${FAR_ONLY}"
assert_equals "a file of only far-future dates is not mixed" "0" \
  "$(mixes_far_and_near < "${FAR_ONLY}" && echo 1 || echo 0)"

# --- reading which tests changed verdict --------------------------------------------------------------
BEFORE="${WORK}/before.log"
AFTER="${WORK}/after.log"
printf 'Failing tests:\n\tSomeSuite.alreadyRed()\n' > "${BEFORE}"
printf 'Failing tests:\n\tSomeSuite.alreadyRed()\n\tOther.wentRedFromTheShift()\n' > "${AFTER}"
NEWLY="$(newly_failing "${BEFORE}" "${AFTER}")"
assert_contains "a test that went red only under the shift is named" "${NEWLY}" "wentRedFromTheShift"
assert_not_contains "one that was already red is not" "${NEWLY}" "alreadyRed"

# A test that was RED and went GREEN is the same finding wearing the other sign: its assertion depended
# on the show being far future too. Silently keeping only one direction would report half the answer.
FIXED="$(newly_passing "${AFTER}" "${BEFORE}")"
assert_contains "a test that went green only under the shift is named too" \
  "${FIXED}" "wentRedFromTheShift"

# --- nothing measured is its own answer ---------------------------------------------------------------
# A run that shifted no file and one where every fixture is already near leave the same empty result,
# and the emptiest possible failure must not read as the cleanest possible pass (L98).
EMPTY_BEFORE="${WORK}/e1.log"
EMPTY_AFTER="${WORK}/e2.log"
: > "${EMPTY_BEFORE}"; : > "${EMPTY_AFTER}"
assert_empty "two logs naming no failing test produce no finding" \
  "$(newly_failing "${EMPTY_BEFORE}" "${EMPTY_AFTER}")"
assert_equals "and a log carrying no suite result at all is refused rather than read as clean" "1" \
  "$(run_reported_nothing "${EMPTY_BEFORE}" && echo 1 || echo 0)"
GOOD_LOG="${WORK}/good.log"
printf 'Test run with 8363 tests in 1146 suites passed after 500 seconds.\n' > "${GOOD_LOG}"
assert_equals "a log that reports a run is not refused" "0" \
  "$(run_reported_nothing "${GOOD_LOG}" && echo 1 || echo 0)"

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "FAILED: ${FAILURES} check-far-future-fixtures.sh assertion(s) failed"
  exit 1
fi
echo "All check-far-future-fixtures.sh fixtures passed"
