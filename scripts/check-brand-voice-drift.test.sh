#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/shell-assertions.sh"

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

# --- #2961: the skill's two halves compared on FACTS, not on a list of banned phrases ----------------
#
# #1227 asked for exactly this and what shipped was a loop over a hand-maintained list of superseded
# PHRASES, which catches the case it was built from and nothing else (L96). This is keyed on the SUBJECT.

MD_RATE='Dan charges $250/hr plus tax with a minimum of one hour.'
REF_SAME='A reply quotes the paragraph: $250/hr plus tax, minimum of one hour.'
REF_STALE='An older note says $195/hr plus tax, minimum of two hours.'

OUT="$(intra_skill_fact_drift "${MD_RATE}" "${REF_STALE}")"; STATUS=$?
assert_contains "intra-skill facts: two different rates is a drift" "${OUT}" "the hourly rate"
assert_contains "intra-skill facts: it names one value" "${OUT}" "250"
assert_contains "intra-skill facts: and the other" "${OUT}" "195"
assert_equals "intra-skill facts: a drift does not exit 0" "1" \
  "$([ "${STATUS}" -ne 0 ] && echo 1 || echo 0)"

OUT="$(intra_skill_fact_drift "${MD_RATE}" "${REF_SAME}")"; STATUS=$?
assert_empty "intra-skill facts: two halves that agree report nothing" "${OUT}"
assert_equals "intra-skill facts: agreement exits 0" "0" "${STATUS}"

# Silence is not a claim. The references are the DETAIL and SKILL.md is the summary; neither repeats all
# of the other, so demanding both state everything would fire on the ordinary case (L93).
OUT="$(intra_skill_fact_drift "${MD_RATE}" "This half says nothing about money at all.")"; STATUS=$?
assert_empty "intra-skill facts: a fact only one half mentions is not a contradiction" "${OUT}"
assert_equals "intra-skill facts: a one-sided fact exits 0" "0" "${STATUS}"

# Found by running this against the REAL skill, which writes "within 2 weeks" in SKILL.md and "within two
# weeks" in the references. Comparing the raw forms accused on the first run: one fact spelled two ways is
# not two facts disagreeing (L185, group by the normalized form and never the raw one).
OUT="$(intra_skill_fact_drift 'the full gallery within 2 weeks' 'the gallery comes back within two weeks')"
assert_empty "intra-skill facts: two spellings of one number are one value" "${OUT}"

# And a real turnaround disagreement still reports, so the normalizing narrowed the reading rather than
# switching it off (L159).
OUT="$(intra_skill_fact_drift 'the full gallery within 2 weeks' 'the gallery comes back within six weeks')"
assert_contains "intra-skill facts: a real turnaround disagreement is still caught" "${OUT}" \
  "the gallery turnaround"

# Every entry names a subject and captures a value, so a malformed one cannot silently check nothing.
for entry in "${BRAND_VOICE_SKILL_FACTS[@]}"; do
  assert_equals "intra-skill facts: '${entry%%|*}' names a subject" "1" \
    "$([ -n "${entry%%|*}" ] && [ "${entry%%|*}" != "${entry}" ] && echo 1 || echo 0)"
  assert_contains "intra-skill facts: '${entry%%|*}' captures a value" "${entry#*|}" "("
done

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "check-brand-voice-drift.test.sh: all assertions passed"
  exit 0
else
  echo "check-brand-voice-drift.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
