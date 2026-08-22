#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/shell-assertions.sh"

# Fixture for scripts/check-prep-eval-freshness.sh (#1867), auto-run by scripts/run-shell-fixtures.sh
# (and so by scripts/test-all.sh).
#
# docs/prep-runbook.md is a prompt with no compiler behind it. The only thing that scores real model
# output against its rules is scripts/eval-prep-runbook.sh --yes, which spends tokens and is wired
# into no CI job, so it rests entirely on somebody remembering. It did not hold: the harness could
# not start at all from 2026-07-28 to 2026-07-31 (#1862) and nobody noticed, and two runbook edits
# (#1856, #1817) reached main before anything had scored either.
#
# The check warns, never blocks, so what has to be right is WHAT IT SAYS. Four states have to stay
# apart from each other, because reporting one as another is the whole defect:
#   fresh          the eval completed against this exact runbook text
#   stale          the runbook changed since the last completed eval
#   never run      no eval has ever completed here, which is NOT the same as long stale
#   cannot judge   this machine cannot run the paid eval at all (CI, a clone without the CLI)
#
# Nothing here spends a token or touches the real record at ${REPO_ROOT}/.overture-eval-last-run:
# every case drives the pure verdict function or runs the script against a throwaway record path.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./check-prep-eval-freshness.sh
source "${SCRIPT_DIR}/check-prep-eval-freshness.sh"
# The sourced script's own `set -euo pipefail` is now active in this shell. Turn errexit off so one
# failing assertion does not abort the rest of the run.
set +e

CHECK="${SCRIPT_DIR}/check-prep-eval-freshness.sh"
RUNBOOK="${SCRIPT_DIR}/../docs/prep-runbook.md"

fails=0
pass_msg() { echo "  ok: $1"; }
fail_msg() { echo "  FAIL: $1"; fails=$((fails + 1)); }

check() {
  local desc="$1"
  if eval "$2"; then pass_msg "${desc}"; else fail_msg "${desc}"; fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass_msg "${desc}"
  else
    fail_msg "${desc}"
    echo "    expected to contain: ${needle}"
    echo "    actual: ${haystack}"
  fi
}

assert_lacks() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass_msg "${desc}"
  else
    fail_msg "${desc}"
    echo "    expected NOT to contain: ${needle}"
    echo "    actual: ${haystack}"
  fi
}

# Every assertion below calls one of these. A shell assertion that invokes a helper which does not
# exist prints "command not found" to stderr and is scored as a plain failure or, inside a
# `$(...)`, as an empty string that some other assertion happily accepts. So prove the helpers are
# really here before running anything that would otherwise report on their absence by accident.
echo "check-prep-eval-freshness.sh: the helpers this fixture drives exist:"
missing=0
for fn in prep_eval_runbook_fingerprint prep_eval_record_field prep_eval_write_last_run \
          prep_eval_last_run_file prep_eval_freshness; do
  if declare -F "${fn}" >/dev/null 2>&1; then
    pass_msg "${fn} is defined"
  else
    fail_msg "${fn} is NOT defined, so nothing below it could be judged"
    missing=$((missing + 1))
  fi
done
if [[ "${missing}" -gt 0 ]]; then
  echo "check-prep-eval-freshness.test.sh: ${missing} helper(s) missing; refusing to report on assertions that cannot mean anything"
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/overture-eval-freshness.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# A stub `claude` so the script sees a machine that CAN run the paid eval. It is never invoked: the
# check only ever asks whether the CLI exists.
mkdir -p "${TMP}/bin"
printf '#!/bin/sh\nexit 0\n' > "${TMP}/bin/claude"
chmod +x "${TMP}/bin/claude"
# git is needed to fingerprint; claude must come only from the stub, never from this Mac's real one.
STUB_PATH="${TMP}/bin:/usr/bin:/bin"
BARE_PATH="/usr/bin:/bin"

# --- the fingerprint: CONTENT, never mtime ------------------------------------------------------
#
# A time comparison is the obvious way to write this check and it is wrong in both directions. A
# fresh clone rewrites every file's mtime, so the runbook would read as newer than any real eval on
# a machine that had just run one; and `touch` on the record would report an eval that never
# happened. The record has to name the runbook TEXT that was scored.
echo
echo "the runbook fingerprint:"

printf 'rule one\nrule two\n' > "${TMP}/a.md"
printf 'rule one\nrule two\n' > "${TMP}/b.md"
printf 'rule one\nrule two CHANGED\n' > "${TMP}/c.md"

check "identical text fingerprints identically, whatever the file is called" \
  '[[ "$(prep_eval_runbook_fingerprint "${TMP}/a.md")" == "$(prep_eval_runbook_fingerprint "${TMP}/b.md")" ]]'
check "a changed rule changes the fingerprint" \
  '[[ "$(prep_eval_runbook_fingerprint "${TMP}/a.md")" != "$(prep_eval_runbook_fingerprint "${TMP}/c.md")" ]]'

before_touch="$(prep_eval_runbook_fingerprint "${TMP}/a.md")"
# An explicit far-off stamp, not a bare `touch`: two files written in the same second share an mtime,
# so a bare touch would leave a fingerprint that IS the mtime looking correct by coincidence.
touch -t 203001010000 "${TMP}/a.md"
check "touching the file does not change the fingerprint (an mtime is not a record of anything)" \
  '[[ "$(prep_eval_runbook_fingerprint "${TMP}/a.md")" == "${before_touch}" ]]'

check "a runbook that is not there cannot be fingerprinted" \
  '! prep_eval_runbook_fingerprint "${TMP}/no-such-runbook.md" >/dev/null 2>&1'

# --- the verdict --------------------------------------------------------------------------------
echo
echo "the four states, kept apart:"

RECORD="${TMP}/record"
FP_A="$(prep_eval_runbook_fingerprint "${TMP}/a.md")"
FP_C="$(prep_eval_runbook_fingerprint "${TMP}/c.md")"

run_verdict() {
  OUT="$(prep_eval_freshness "$1" "$2")"
  RC=$?
}

# 1. Never run: no record at all. Its own state, its own exit code, and it must not read as stale.
rm -f "${RECORD}"
run_verdict "${FP_A}" "${RECORD}"
assert_contains "never run: says so in those words" "${OUT}" "NEVER RUN"
assert_lacks "never run: never claims the runbook CHANGED (nothing to change against)" "${OUT}" "CHANGED"
check "never run: its own return code (2)" '[[ "${RC}" -eq 2 ]]'

# 2. Fresh: the record names this exact runbook text.
prep_eval_write_last_run "${RECORD}" "${FP_A}" "2026-08-11T09:00:00Z" 13 13 13 "${TMP}/runs/20260811-090000" \
  "a b c d e f g h i j k l m" 13
run_verdict "${FP_A}" "${RECORD}"
assert_contains "fresh: reports OK" "${OUT}" "OK:"
assert_contains "fresh: names when the eval completed" "${OUT}" "2026-08-11T09:00:00Z"
assert_contains "fresh: names how many fixtures were scored" "${OUT}" "13 of 13"
check "fresh: return code 0" '[[ "${RC}" -eq 0 ]]'

# 3. Stale: the runbook has changed since that completed run.
run_verdict "${FP_C}" "${RECORD}"
assert_contains "stale: says the runbook has changed" "${OUT}" "CHANGED"
assert_contains "stale: names when the last eval completed, so long stale is visible as long" \
  "${OUT}" "2026-08-11T09:00:00Z"
assert_lacks "stale: does not report a stale record as never run" "${OUT}" "NEVER RUN"
check "stale: its own return code (1)" '[[ "${RC}" -eq 1 ]]'

# 4. A record that exists but says nothing usable. Absent and unreadable are different facts, and
#    reporting an unreadable one as "never run" would send someone to spend tokens they may not
#    need to (L11, L105).
printf 'completed 2026-08-11T09:00:00Z\n' > "${RECORD}"
run_verdict "${FP_A}" "${RECORD}"
assert_contains "unreadable: reports the record itself as the problem" "${OUT}" "UNREADABLE"
assert_lacks "unreadable: is not reported as never run" "${OUT}" "NEVER RUN"
check "unreadable: its own return code (3)" '[[ "${RC}" -eq 3 ]]'

# A record with a runbook but no completion time cannot say WHEN, so it is unreadable too rather
# than a fresh verdict with a blank where the date goes.
printf 'runbook %s\n' "${FP_A}" > "${RECORD}"
run_verdict "${FP_A}" "${RECORD}"
assert_contains "unreadable: a record with no completion time is not passed off as fresh" "${OUT}" "UNREADABLE"

# --- what the verdict may claim -----------------------------------------------------------------
echo
echo "a fresh verdict claims only what the run measured:"

# A run that scored 1 of 13 fixtures did not evaluate the runbook, it spot-checked it. Saying "OK"
# and stopping there would let a targeted recheck stand in for the full set.
prep_eval_write_last_run "${RECORD}" "${FP_A}" "2026-08-11T09:00:00Z" 1 13 1 "${TMP}/runs/x" "a" 1
run_verdict "${FP_A}" "${RECORD}"
check "targeted: still fresh (return code 0)" '[[ "${RC}" -eq 0 ]]'
assert_contains "targeted: says the run covered only part of the fixture set" "${OUT}" "1 of 13"
assert_contains "targeted: names the rest as unscored rather than implying a full pass" "${OUT}" "TARGETED"

# A completed run that FAILED fixtures is fresh and is also bad news. Reporting only the freshness
# would be a green line over a judgment layer that said no.
prep_eval_write_last_run "${RECORD}" "${FP_A}" "2026-08-11T09:00:00Z" 13 13 11 "${TMP}/runs/y" \
  "a b c d e f g h i j k l m" 11
run_verdict "${FP_A}" "${RECORD}"
assert_contains "failing: names the fixtures the last run left failing" "${OUT}" "2 fixture"
assert_contains "failing: points at the cheap recheck for them" "${OUT}" "--yes --failed"

# --- coverage carried across runs (#2581) -------------------------------------------------------
echo
echo "a recheck does not shrink what the record says has been covered:"

# The measured shape: a 13/13 pass, then a one-fixture recheck. `scored` is honestly 1, because that is
# what THIS run did, and coverage against these same rules is still 13. Reading the first number as
# coverage is what made a recheck look like a loss of ground.
prep_eval_write_last_run "${RECORD}" "${FP_A}" "2026-08-12T13:36:00Z" 1 13 1 "${TMP}/runs/recheck" \
  "a b c d e f g h i j k l m" 13
run_verdict "${FP_A}" "${RECORD}"
check "recheck: still fresh (return code 0)" '[[ "${RC}" -eq 0 ]]'
assert_contains "recheck: coverage is stated as the full set, not as the one fixture rechecked" \
  "${OUT}" "13 of 13"
assert_lacks "recheck: is not reported as a targeted spot check of the whole rules" "${OUT}" "TARGETED"
# Needle chosen to be unambiguous: "1 fixture" is a substring of "13 fixtures scored" on the line
# above it, so it would pass without the sentence it is about ever being printed.
assert_contains "recheck: still says what THIS run scored, so the two are not confused" "${OUT}" "re-scored 1"

# Coverage, not this run, is what decides whether the rest is unscored. A record whose cumulative set is
# short must still say so however complete the last run looked on its own.
prep_eval_write_last_run "${RECORD}" "${FP_A}" "2026-08-12T13:36:00Z" 4 13 4 "${TMP}/runs/partial" \
  "a b c d" 4
run_verdict "${FP_A}" "${RECORD}"
assert_contains "partial coverage: names the rest as unscored" "${OUT}" "TARGETED"
assert_contains "partial coverage: counts by the covered set" "${OUT}" "4 of 13"

# Outstanding failures are counted over the COVERED set too, so a recheck that passes its own one
# fixture cannot silence the failures the earlier run left in the other twelve.
prep_eval_write_last_run "${RECORD}" "${FP_A}" "2026-08-12T13:36:00Z" 1 13 1 "${TMP}/runs/recheck2" \
  "a b c d e f g h i j k l m" 10
run_verdict "${FP_A}" "${RECORD}"
assert_contains "recheck: still names the failures outstanding across the covered set" "${OUT}" "left 3 fixture"
assert_contains "recheck: points at the cheap recheck for them" "${OUT}" "--yes --failed"

# A record written BEFORE these fields existed has no cumulative set. That is a real absence, not a
# caller's omission, and it must read exactly as it did before rather than as zero coverage.
printf 'runbook %s\ncompleted 2026-08-11T09:00:00Z\nscored 13\navailable 13\npassed 13\n' "${FP_A}" \
  > "${RECORD}"
run_verdict "${FP_A}" "${RECORD}"
check "an older record is still read (return code 0)" '[[ "${RC}" -eq 0 ]]'
assert_contains "an older record still reports its own numbers" "${OUT}" "13 of 13"
assert_lacks "and is never reported as covering nothing" "${OUT}" "0 of 13"

# --- the script end to end ----------------------------------------------------------------------
echo
echo "the script itself, end to end:"

E2E_RECORD="${TMP}/e2e-record"
run_check() {
  OUT="$(PATH="$1" OVERTURE_EVAL_LAST_RUN_FILE="${E2E_RECORD}" "${CHECK}" "${2:-${RUNBOOK}}" 2>&1)"
  RC=$?
}

# A machine that cannot run the paid eval at all (no claude CLI: CI, a fresh clone) must skip
# cleanly, exactly as check-brand-voice-drift.sh does when the skill is not installed. Warning there
# would be a permanent false alarm about a run that machine could never have made (L36).
rm -f "${E2E_RECORD}"
run_check "${BARE_PATH}"
assert_contains "no claude CLI: skips cleanly and says why" "${OUT}" "SKIPPED"
assert_lacks "no claude CLI: does not cry never run at a machine that could never run it" "${OUT}" "NEVER RUN"
check "no claude CLI: exit 0" '[[ "${RC}" -eq 0 ]]'

# Never run, on a machine that COULD run it: the warning appears, and it still does not block.
run_check "${STUB_PATH}"
assert_contains "never run: warns" "${OUT}" "NEVER RUN"
assert_contains "never run: names the hand run that would fix it" "${OUT}" "scripts/eval-prep-runbook.sh --yes"
assert_contains "never run: says plainly that it is not a gate" "${OUT}" "not a gate"
check "never run: exits 0, because this warns and never blocks" '[[ "${RC}" -eq 0 ]]'

# Fresh against the REAL runbook in this checkout.
prep_eval_write_last_run "${E2E_RECORD}" "$(prep_eval_runbook_fingerprint "${RUNBOOK}")" \
  "2026-08-11T09:00:00Z" 13 13 13 "${TMP}/runs/z" "a b c d e f g h i j k l m" 13
run_check "${STUB_PATH}"
assert_contains "fresh: reports OK against the runbook actually in this checkout" "${OUT}" "OK:"
check "fresh: exit 0" '[[ "${RC}" -eq 0 ]]'

# Stale: the same record against a DIFFERENT runbook file is the shape of an edited runbook.
run_check "${STUB_PATH}" "${TMP}/c.md"
assert_contains "stale: warns that the rules changed since the last completed eval" "${OUT}" "CHANGED"
check "stale: exits 0 even so, because it must never block a push" '[[ "${RC}" -eq 0 ]]'

# A runbook that is not there is a broken invocation, not a freshness verdict.
run_check "${STUB_PATH}" "${TMP}/no-such-runbook.md"
assert_contains "missing runbook: reports an error rather than a verdict" "${OUT}" "ERROR"
check "missing runbook: exits 2" '[[ "${RC}" -eq 2 ]]'

echo
if [[ "${fails}" -eq 0 ]]; then
  echo "check-prep-eval-freshness.test.sh: PASS"
  exit 0
fi
echo "check-prep-eval-freshness.test.sh: ${fails} assertion(s) failed"
exit 1
