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
RUNBOOK_MISSING_OPENER="$(all_anchors_text | grep -v 'direct-intent')"
run_drift "${RUNBOOK_MISSING_OPENER}" "${FULL}"
assert_contains "drift: names the runbook as the side missing it" "${OUT}" 'missing from runbook'
assert_contains "drift: reports the missing opener anchor" "${OUT}" 'direct-intent'

# 4. Wrapped (the load-bearing case): "Lincoln Center" split across a newline in the runbook must
#    still match, so the check does not false-alarm on a normal line wrap.
RUNBOOK_WRAPPED="${FULL/Lincoln Center/Lincoln$'\n'Center}"
run_drift "${RUNBOOK_WRAPPED}" "${FULL}"
assert_empty "wrapped: a line-wrapped anchor does not read as drift" "${OUT}"
assert_eq "wrapped: return code is 0" "0" "${RC}"

# --- intra-skill contradiction (#1227) ---------------------------------------------------
# The skill states guidance twice (SKILL.md summary + references/*). A superseded phrase may appear
# ONLY as a negative instruction; an un-negated occurrence is one file endorsing what another rejects,
# the exact #1215 miss (SKILL.md preferred "let me know how that lands" while its own references rejected
# it, and the presence-only drift check passed anyway).
run_contradiction() {
  OUT="$(intra_skill_contradiction "$1" "$2")"
  RC=$?
}

REJECTED='let me know how that lands'

# a. Contradiction: SKILL.md ENDORSES the rejected phrase (no negation) while references reject it.
run_contradiction "Prefer a close like \"${REJECTED}\" here." "Never \"${REJECTED}\"; Dan rejected it."
assert_contains "intra-skill: an un-negated rejected phrase is reported" "${OUT}" "${REJECTED}"
assert_contains "intra-skill: names SKILL.md as the offending side" "${OUT}" "SKILL.md"
if [[ "${RC}" -ne 0 ]]; then
  echo "ok - intra-skill: nonzero return on contradiction (${RC})"
else
  echo "FAIL - intra-skill: expected nonzero return code, got 0"
  FAILURES=$((FAILURES + 1))
fi

# b. Clean: both files NEGATE the rejected phrase, so there is no contradiction.
run_contradiction "Prefer \"Happy to answer any questions.\" Never \"${REJECTED}.\"" "Never \"${REJECTED}\", it reads poorly."
assert_empty "intra-skill: both sides negating the phrase is not a contradiction" "${OUT}"
assert_eq "intra-skill: return code 0 when consistent" "0" "${RC}"

# c. Clean: neither file mentions the phrase at all.
run_contradiction "Prefer a soft close." "Hold boundaries positively."
assert_empty "intra-skill: absence of the phrase is not a contradiction" "${OUT}"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "check-brand-voice-drift.test.sh: all assertions passed"
  exit 0
else
  echo "check-brand-voice-drift.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
