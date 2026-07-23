#!/usr/bin/env bash
set -euo pipefail

# Pure-shell fixture for scripts/eval-prep-runbook.sh (#591), auto-run by scripts/run-shell-fixtures.sh
# (and so by scripts/test-all.sh). It exercises ONLY the no-spend paths: the whole point of the harness
# is that it never makes a real (token-spending) claude call except behind an explicit --yes, so this
# test never passes --yes and asserts every other path is safe and correct. The real-AI path itself is
# opt-in and out of scope for an automated test by design.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/eval-prep-runbook.sh"

fails=0
check() {
  local desc="$1"
  if eval "$2"; then
    echo "  ok: ${desc}"
  else
    echo "  FAIL: ${desc}"
    fails=$((fails + 1))
  fi
}

echo "eval-prep-runbook.sh no-spend paths:"

# A bare invocation warns loudly that the real run spends tokens, and spends nothing itself.
warning="$("${SCRIPT}" 2>&1 || true)"
check "bare invocation prints the real-AI cost warning" \
  '[[ "${warning}" == *"REAL AI calls"* && "${warning}" == *"SPENDS TOKENS"* ]]'

# --list names every committed fixture.
listing="$("${SCRIPT}" --list)"
for expected in already-covered-photographer carnegie-citywide-press-inbox host-venue-not-target \
                presenter-not-venue self-produced-duo-both-performers stale-site-misnamed-co-performer; do
  check "--list includes ${expected}" '[[ "${listing}" == *"'"${expected}"'"* ]]'
done

# --dry-run prints the prompt (runbook + the item's own material) without calling claude.
if command -v jq >/dev/null 2>&1; then
  dry="$("${SCRIPT}" --dry-run carnegie-citywide-press-inbox)"
  check "--dry-run embeds the runbook" '[[ "${dry}" == *"Runbook (docs/prep-runbook.md)"* ]]'
  check "--dry-run embeds the fixture's own listing" '[[ "${dry}" == *"Solaris Quartet"* ]]'
  check "--dry-run forbids web research (reproducible eval)" '[[ "${dry}" == *"Do NOT fetch the web"* ]]'
else
  echo "  skip: jq not installed, --dry-run assertions skipped"
fi

# --self-check scores every fixture's own compliant sample through the real engine; all must pass.
if command -v pnpm >/dev/null 2>&1 || command -v tsx >/dev/null 2>&1; then
  self="$("${SCRIPT}" --self-check)"
  check "--self-check reports all fixtures clean" '[[ "${self}" == *"all fixtures self-check clean"* ]]'
  check "--self-check reports no FAIL line" '[[ "${self}" != *"FAIL"* ]]'
else
  echo "  skip: neither pnpm nor tsx installed, --self-check assertions skipped"
fi

# An unknown option is rejected (exit 2), never treated as a real run.
rc=0; "${SCRIPT}" --nonsense >/dev/null 2>&1 || rc=$?
check "unknown option exits nonzero (never a silent real run)" '[[ "${rc}" -eq 2 ]]'

# #1387: the real-AI loop used to read fixture names from stdin, so the inner claude/tsx call (both read
# stdin) swallowed the rest and only the FIRST of 8 fixtures ever ran. for_each_fixture must visit EVERY
# fixture even when its callback consumes stdin. Source the script (main is source-guarded, so nothing
# spends) and drive for_each_fixture with a stdin-eating callback; a truncating loop visits 1, the fixed
# loop visits all of them. Token-free: the callback never calls claude.
visited=""
count_visits() { cat >/dev/null 2>&1 || true; visited="${visited}${1} "; }
# shellcheck source=/dev/null
source "${SCRIPT}"
for_each_fixture count_visits </dev/null
n_visited="$(printf '%s' "${visited}" | wc -w | tr -d ' ')"
n_fixtures="$(list_fixtures | wc -l | tr -d ' ')"
check "for_each_fixture visits every fixture despite a stdin-consuming callback" \
  '[[ "${n_visited}" == "${n_fixtures}" && "${n_visited}" -gt 1 ]]'

# #1397: --yes accepts an optional single fixture name so a targeted recheck after a focused runbook edit
# is one claude call, not eight. The SELECTION is token-free and testable: drive select_and_run with a
# recorder callback (never claude) and assert it dispatches to exactly the right fixtures. A bad name must
# be a usage error, never a silent no-op and never a silent full real run.
selected=""
record_selected() { selected="${selected}${1} "; }

selected=""
select_and_run record_selected stale-site-misnamed-co-performer </dev/null
check "--yes NAME runs exactly the one named fixture" \
  '[[ "${selected}" == "stale-site-misnamed-co-performer " ]]'

selected=""
rc=0; select_and_run record_selected no-such-fixture </dev/null 2>/dev/null || rc=$?
check "--yes with an unknown fixture is a usage error (exit 2)" '[[ "${rc}" -eq 2 ]]'
check "--yes with an unknown fixture runs nothing" '[[ -z "${selected}" ]]'

selected=""
select_and_run record_selected </dev/null
n_all="$(printf '%s' "${selected}" | wc -w | tr -d ' ')"
check "--yes with no name still runs every fixture" \
  '[[ "${n_all}" == "${n_fixtures}" && "${n_all}" -gt 1 ]]'

# #1400: --yes --failed rechecks only the fixtures a prior real run left failing, and the failures record
# converges (fixtures retested-and-passed drop off; still-failing stay; untested stay). Token-free: point
# FAILURES_FILE at a temp path and drive the failure-tracking functions with the recorder, never claude.
FAILURES_FILE="$(mktemp -t overture-eval-failures.XXXXXX)"
trap 'rm -f "${FAILURES_FILE}"' EXIT

# read_failures yields nothing until a run has recorded something.
rm -f "${FAILURES_FILE}"
check "read_failures is empty when no run has recorded failures" '[[ -z "$(read_failures)" ]]'

# --failed with no recorded failures is a usage error (exit 2) that runs nothing (never a silent full run).
selected=""
rc=0; run_failed_fixtures record_selected 2>/dev/null || rc=$?
check "--failed with no recorded failures exits 2" '[[ "${rc}" -eq 2 ]]'
check "--failed with no recorded failures runs nothing" '[[ -z "${selected}" ]]'

# Given two REAL recorded failures, --failed reruns exactly those two.
printf '%s\n' host-venue-not-target presenter-not-venue > "${FAILURES_FILE}"
selected=""
run_failed_fixtures record_selected
check "--failed reruns exactly the recorded failing fixtures" \
  '[[ "${selected}" == "host-venue-not-target presenter-not-venue " ]]'

# A recorded name that is no longer a fixture is skipped; the still-valid one still runs.
printf '%s\n' host-venue-not-target renamed-away-fixture > "${FAILURES_FILE}"
selected=""
run_failed_fixtures record_selected 2>/dev/null
check "--failed skips a stale recorded name but still runs the valid one" \
  '[[ "${selected}" == "host-venue-not-target " ]]'

# Convergence: prior failures {host, presenter, already-covered}; this run retested {host, presenter},
# host passed, presenter still failed. Result must be {already-covered, presenter}: host drops (retested +
# passed), presenter stays (still failing), already-covered stays (never retested).
printf '%s\n' host-venue-not-target presenter-not-venue already-covered-photographer > "${FAILURES_FILE}"
_eval_ran_names=$'host-venue-not-target\npresenter-not-venue\n'
_eval_failed_names=$'presenter-not-venue\n'
update_failures_file
after="$(read_failures | sort | tr '\n' ' ')"
check "update_failures_file drops retested-passing, keeps still-failing and untested" \
  '[[ "${after}" == "already-covered-photographer presenter-not-venue " ]]'

# When every prior failure was retested and passed, the record empties out.
printf '%s\n' host-venue-not-target > "${FAILURES_FILE}"
_eval_ran_names=$'host-venue-not-target\n'
_eval_failed_names=""
update_failures_file
check "update_failures_file empties the record when all prior failures now pass" '[[ -z "$(read_failures)" ]]'

if [[ "${fails}" -eq 0 ]]; then
  echo "eval-prep-runbook.test.sh: PASS"
  exit 0
fi
echo "eval-prep-runbook.test.sh: ${fails} assertion(s) failed"
exit 1
