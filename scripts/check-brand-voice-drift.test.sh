#!/usr/bin/env bash
set -uo pipefail

# Pure-function coverage for check-brand-voice-drift.sh's brand_voice_drift (#731). The real
# check reads docs/prep-runbook.md and the external dan-wright-brand-voice skill, which lives
# OUTSIDE this repo and so can't ride in CI. This fixture drives the comparison against throwaway
# text instead, so it runs anywhere (including CI) without the skill installed.
#
# The load-bearing case is `wrapped`: a real edit already wraps "Lincoln Center" across a line
# break in the runbook, so a naive substring match reports it as drifted when it isn't. Without
# the normalizer that collapses newlines, that case goes red, which is exactly the mutation this
# fixture is here to catch.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./check-brand-voice-drift.sh
source "${SCRIPT_DIR}/check-brand-voice-drift.sh"
# check-brand-voice-drift.sh's own `set -euo pipefail` is now active in this shell too. Turn
# errexit off so one failing assertion doesn't abort the rest of the run.
set +e

FAILURES=0

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

# Every anchor on its own line: a fully-in-sync side.
all_anchors_text() {
  printf '%s\n' "${BRAND_VOICE_ANCHORS[@]}"
}

# Runs brand_voice_drift, capturing its printed drift lines in OUT and its return code in RC.
run_drift() {
  OUT="$(brand_voice_drift "$1" "$2")"
  RC=$?
}

FULL="$(all_anchors_text)"

# 1. Green: both sides carry every anchor -> no drift, clean return.
run_drift "${FULL}" "${FULL}"
assert_empty "green: no drift lines when both sides agree" "${OUT}"
assert_eq "green: return code is 0" "0" "${RC}"

# 2. Drift on the skill side: an anchor dropped from the skill is reported against the skill.
SKILL_MISSING_RADIO="$(all_anchors_text | grep -v 'Radio City Music Hall')"
run_drift "${FULL}" "${SKILL_MISSING_RADIO}"
assert_contains "drift: reports the missing anchor against the skill" "${OUT}" 'Radio City Music Hall'
assert_contains "drift: names the skill as the side missing it" "${OUT}" 'missing from skill'
if [[ "${RC}" -ne 0 ]]; then
  echo "ok - drift: nonzero return code (${RC})"
else
  echo "FAIL - drift: expected nonzero return code, got 0"
  FAILURES=$((FAILURES + 1))
fi

# 3. Drift on the runbook side: an anchor dropped from the runbook is reported against the runbook.
RUNBOOK_MISSING_OPENER="$(all_anchors_text | grep -v 'observation-first')"
run_drift "${RUNBOOK_MISSING_OPENER}" "${FULL}"
assert_contains "drift: names the runbook as the side missing it" "${OUT}" 'missing from runbook'
assert_contains "drift: reports the missing opener anchor" "${OUT}" 'observation-first'

# 4. Wrapped (the load-bearing case): "Lincoln Center" split across a newline in the runbook must
#    still match, so the check does not false-alarm on a normal line wrap.
RUNBOOK_WRAPPED="${FULL/Lincoln Center/Lincoln$'\n'Center}"
run_drift "${RUNBOOK_WRAPPED}" "${FULL}"
assert_empty "wrapped: a line-wrapped anchor does not read as drift" "${OUT}"
assert_eq "wrapped: return code is 0" "0" "${RC}"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "check-brand-voice-drift.test.sh: all assertions passed"
  exit 0
else
  echo "check-brand-voice-drift.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
