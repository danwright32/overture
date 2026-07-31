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

# The shared list-runner primitive backs both the full run and the targeted reruns: it must dispatch the
# callback over EXACTLY the names it is given (run_plan already chose the set), with the same FD-3 discipline
# as for_each_fixture so a stdin-eating callback can't truncate it. Token-free: the recorder never spends.
selected=""
record_selected() { selected="${selected}${1} "; }
for_each_in_list record_selected $'host-venue-not-target\npresenter-not-venue\n' </dev/null
check "for_each_in_list dispatches over exactly the names given" \
  '[[ "${selected}" == "host-venue-not-target presenter-not-venue " ]]'

# #1397/#1400 warning-ordering (#1400 follow-up): run_plan is the single token-free resolver for WHICH
# fixtures a real run would score. real_run calls it BEFORE the SPENDS-TOKENS warning and any setup, so a
# no-op selection resolves to nothing and exits 2 as a free usage error, and the warning is therefore never
# printed on a run that spends nothing. These assertions pin exactly that: the no-op cases resolve empty + 2.

# #1397: a single named fixture resolves to exactly itself; an unknown name is a usage error resolving nothing.
check "run_plan NAME resolves to exactly that fixture" \
  '[[ "$(run_plan stale-site-misnamed-co-performer)" == "stale-site-misnamed-co-performer" ]]'
rc=0; out="$(run_plan no-such-fixture 2>/dev/null)" || rc=$?
check "run_plan with an unknown fixture exits 2" '[[ "${rc}" -eq 2 ]]'
check "run_plan with an unknown fixture resolves nothing (no run, no token warning)" '[[ -z "${out}" ]]'

# No name resolves the full fixture set.
n_all="$(run_plan "" | wc -l | tr -d ' ')"
check "run_plan with no name resolves every fixture" '[[ "${n_all}" == "${n_fixtures}" && "${n_all}" -gt 1 ]]'

# #1400: --yes --failed resolves to only the fixtures a prior real run left failing, and the record converges
# (retested-and-passed drop off; still-failing stay; untested stay). Token-free: FAILURES_FILE -> temp path.
FAILURES_FILE="$(mktemp -t overture-eval-failures.XXXXXX)"
trap 'rm -f "${FAILURES_FILE}"' EXIT

# read_failures yields nothing until a run has recorded something.
rm -f "${FAILURES_FILE}"
check "read_failures is empty when no run has recorded failures" '[[ -z "$(read_failures)" ]]'

# --failed with no record resolves nothing and exits 2 (never a silent full run, never a token warning).
rc=0; out="$(run_plan --failed 2>/dev/null)" || rc=$?
check "run_plan --failed with no record exits 2" '[[ "${rc}" -eq 2 ]]'
check "run_plan --failed with no record resolves nothing (no run, no token warning)" '[[ -z "${out}" ]]'

# Given two REAL recorded failures, --failed resolves exactly those two.
printf '%s\n' host-venue-not-target presenter-not-venue > "${FAILURES_FILE}"
check "run_plan --failed resolves exactly the recorded failing fixtures" \
  '[[ "$(run_plan --failed | tr "\n" " ")" == "host-venue-not-target presenter-not-venue " ]]'

# A recorded name that is no longer a fixture is skipped; the still-valid one stays.
printf '%s\n' host-venue-not-target renamed-away-fixture > "${FAILURES_FILE}"
check "run_plan --failed skips a stale recorded name but keeps the valid one" \
  '[[ "$(run_plan --failed 2>/dev/null)" == "host-venue-not-target" ]]'

# If EVERY recorded name is stale, that is a usage error resolving nothing, not a silent full run.
printf '%s\n' renamed-away-fixture > "${FAILURES_FILE}"
rc=0; out="$(run_plan --failed 2>/dev/null)" || rc=$?
check "run_plan --failed with only stale names exits 2" '[[ "${rc}" -eq 2 ]]'
check "run_plan --failed with only stale names resolves nothing" '[[ -z "${out}" ]]'

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

# --- the model override (#1597) -----------------------------------------------------------------------
#
# The harness must be able to score a DIFFERENT model tier against the same fixtures. That is how
# "would sonnet or haiku still obey the strict contact rules" was answered with evidence rather than
# opinion: sonnet passed every rule, haiku dropped a required performer, and the decision to halve the
# cost per lookup rests on that measurement being real.
#
# Two claims, and the SECOND matters more. The override must work, and it must not leak: the drafting
# model is pinned on purpose (mac/scripts/lib/models.sh, Dan accepted his voice shifting with each new
# Opus in exchange for the improvement). Were the override a default on that constant, a stray
# environment variable would quietly change which model writes the emails that reach strangers in his
# name, with no error and no symptom. Still a no-spend test: nothing here invokes claude.
echo "the eval model override:"

REPO_ROOT_FOR_MODELS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELS_SH="${REPO_ROOT_FOR_MODELS}/mac/scripts/lib/models.sh"

resolved_model() {
  # Resolve exactly as the harness does, in a subshell, with whatever env the caller set.
  bash -c '. "'"${MODELS_SH}"'" >/dev/null 2>&1; printf "%s" "${OVERTURE_EVAL_MODEL:-${OVERTURE_MODEL_DRAFTING:-opus}}"'
}

check "the override chooses the model the eval runs" \
  '[[ "$(OVERTURE_EVAL_MODEL=sonnet resolved_model)" == "sonnet" ]]'
check "another tier passes through too, not just the first one tried" \
  '[[ "$(OVERTURE_EVAL_MODEL=haiku resolved_model)" == "haiku" ]]'
check "with no override it falls back to the pinned drafting model, so a baseline really is a baseline" \
  '[[ "$(env -u OVERTURE_EVAL_MODEL bash -c "$(declare -f resolved_model); resolved_model")" == "opus" ]]'

# THE LEAK TEST. Setting the eval override must not reach the constant the real runners read: prep-run.sh,
# reply-classify-run.sh and scout-extract-run.sh all source models.sh.
leaked_drafting() {
  bash -c '. "'"${MODELS_SH}"'" >/dev/null 2>&1; printf "%s" "${OVERTURE_MODEL_DRAFTING}"'
}
check "the eval override does NOT bleed into the real drafting model" \
  '[[ "$(OVERTURE_EVAL_MODEL=haiku leaked_drafting)" == "opus" ]]'
# And the constant is not overridable by its own name either, which is the other route to the same accident.
check "the drafting model stays pinned even when its own name is set in the environment" \
  '[[ "$(OVERTURE_MODEL_DRAFTING=haiku leaked_drafting)" == "opus" ]]'

# The harness must actually USE the resolved value; a correct variable nobody passes to claude is a
# guard that reads as solved while every eval silently runs on opus.
EVAL_SH="${REPO_ROOT_FOR_MODELS}/scripts/eval-prep-runbook.sh"
check "the harness passes the resolved model to claude, not the pinned constant" \
  'grep -q -- "--model \"\${_eval_model}\"" "${EVAL_SH}"'
check "and no longer hard-passes the drafting constant" \
  '! grep -q -- "--model \"\${OVERTURE_MODEL_DRAFTING}\"" "${EVAL_SH}"'

# #1862: the REAL run's setup, with nothing spent.
#
# The AI call itself is opt-in and out of scope for a test. Everything IN FRONT of it is not, and treating
# the two as one exemption is how this harness came to be unable to start at all: `claude_run_scope` gained
# a fifth argument in #1682, this script kept passing four, and under `set -u` the helper aborted. Its
# failure was read as "unsafe tool scope", so the whole opt-in layer was dead for three days and every hand
# run failed at the door.
#
# So: a stub `claude` on PATH that answers `plugin list --json` and then anything else, and the assertion
# that a real run REACHES a fixture. It spends nothing (the stub is a shell script) and it fails the moment
# the setup in front of the spend breaks again.
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "${STUB_DIR}"' EXIT
cat > "${STUB_DIR}/claude" <<'STUB'
#!/bin/sh
# `plugin list --json` must answer with the JSON array the lockout requires; every other invocation is
# the drafting call, answered with an empty result so the run gets as far as scoring and no further.
case "$1" in
  plugin) echo '[]' ;;
  *) echo '{"version":8,"generatedAt":"now","results":[]}' ;;
esac
STUB
chmod +x "${STUB_DIR}/claude"

started="$(PATH="${STUB_DIR}:${PATH}" \
  OVERTURE_EVAL_FAILURES_FILE="${STUB_DIR}/failures" \
  "${SCRIPT}" --yes host-venue-not-target 2>&1 || true)"
check "a real run gets past its own tool-scope setup" \
  '[[ "${started}" != *"refusing to run, unsafe tool scope"* ]]'
check "a real run reaches the fixture it was asked for" \
  '[[ "${started}" == *"host-venue-not-target"* ]]'

if [[ "${fails}" -eq 0 ]]; then
  echo "eval-prep-runbook.test.sh: PASS"
  exit 0
fi
echo "eval-prep-runbook.test.sh: ${fails} assertion(s) failed"
exit 1
