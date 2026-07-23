#!/usr/bin/env bash
set -euo pipefail

# On-demand REGRESSION EVAL for the prep-runbook's AI research/drafting judgment (#591).
#
# WHY: docs/prep-runbook.md is a prompt executed as a headless AI run, not code. Its rules (never the host
# venue, never a press inbox, surface both named performers, strict confidence) have no compiler behind
# them, so an edit can silently break an earlier rule and nothing catches it until Dan sees a bad draft.
#
# TWO LAYERS guard it. The ALWAYS-ON, free, structural layer runs on every change via `pnpm test`
# (src/lib/prepRunbookRules.test.ts asserts each rule stays in the runbook text; src/lib/prepEval.test.ts
# scores recorded outputs against the fixture expectations). THIS script is the OPT-IN, real-AI layer: it
# runs the CURRENT runbook against each saved fixture listing through the SAME headless `claude -p`
# mechanism mac/scripts/prep-run.sh uses, then scores the actual output against the fixture's expected
# rule outcome with the SAME engine the vitest suite uses (scripts/eval-prep-runbook.ts -> prepEval.ts).
#
# IT COSTS TOKENS. Run it by hand before shipping a runbook edit. It must NEVER run in CI or on every
# edit, which is why the real run is gated behind an explicit --yes and it is wired into nothing.
#
# Usage:
#   scripts/eval-prep-runbook.sh                 # show this help and the cost warning; spends nothing
#   scripts/eval-prep-runbook.sh --list          # list the fixtures; spends nothing
#   scripts/eval-prep-runbook.sh --self-check    # score each fixture's own compliant sample; spends nothing
#   scripts/eval-prep-runbook.sh --dry-run NAME  # print the prompt for one fixture; spends nothing
#   scripts/eval-prep-runbook.sh --yes           # RUN THE REAL EVAL against every fixture; SPENDS TOKENS
#   scripts/eval-prep-runbook.sh --yes NAME      # RUN THE REAL EVAL against ONE fixture; SPENDS TOKENS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURE_DIR="${REPO_ROOT}/fixtures/prep-eval"
RUNBOOK="${REPO_ROOT}/docs/prep-runbook.md"
CLI="${SCRIPT_DIR}/eval-prep-runbook.ts"

cost_warning() {
  cat >&2 <<'WARN'
============================================================================
  eval-prep-runbook.sh --yes makes REAL AI calls (one claude -p run PER
  fixture) and SPENDS TOKENS on Dan's plan. It is opt-in on purpose and is
  wired into no CI job and no pre-push hook. Run it by hand before shipping a
  docs/prep-runbook.md edit, never automatically.
============================================================================
WARN
}

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

list_fixtures() {
  find "${FIXTURE_DIR}" -name '*.json' | sort | while IFS= read -r f; do
    basename "${f}" .json
  done
}

fixture_path_for() {
  local name="$1"
  echo "${FIXTURE_DIR}/${name}.json"
}

# Builds the prompt for one fixture: the runbook, the single work-list item, and the ONLY sources the run
# may use. The run is told not to fetch the web, so the eval scores the runbook's JUDGMENT on fixed
# material rather than the drift of live sites (and carries no real PII).
build_prompt() {
  local fixture="$1"
  local input sources
  input="$(jq '.input' "${fixture}")"
  sources="$(jq -r '.sources[] | "- \(.label) (\(.url // "no url")):\n\(.content)\n"' "${fixture}")"
  cat <<PROMPT
You are running a REGRESSION EVAL of the Overture Prep runbook. Apply the rules in the runbook below to
the SINGLE work-list item, then output ONLY the resulting PrepResults JSON (version 6) for that one item
and nothing else (no prose, no code fence needed).

IMPORTANT: research ONLY from the "Sources" provided here. Do NOT fetch the web or use any tool; all the
material you are permitted to use is inline below. This keeps the eval reproducible and free of real PII.
Copy the item's naturalKey byte for byte into the result.

Work-list item:
${input}

Sources (the only material available to you):
${sources}

Runbook (docs/prep-runbook.md):
$(cat "${RUNBOOK}")
PROMPT
}

# Script-scoped so score_one_fixture (a for_each_fixture callback) can see them: a bash callback cannot
# capture the caller's locals.
_eval_claude=""
_eval_scope=""
_eval_tmp=""
_eval_failures=0
_eval_total=0

# Score ONE fixture: run the drafter on it, then check the output. A malformed or errored AI run counts
# as that fixture failing and never aborts the rest. claude's stdin is /dev/null so it can neither block
# on nor (with the FD-3 loop below) truncate the fixture list.
score_one_fixture() {
  local name="$1" fixture="$2" prompt out
  _eval_total=$((_eval_total + 1))
  echo "==> ${name}: running claude..."
  prompt="$(build_prompt "${fixture}")"
  out="${_eval_tmp}/${name}.out"
  # shellcheck disable=SC2086  # $_eval_scope MUST word-split into --allowedTools <list> --permission-mode <mode>
  if ! "${_eval_claude}" -p "${prompt}" --model "${OVERTURE_MODEL_DRAFTING}" ${_eval_scope} </dev/null > "${out}" 2>"${_eval_tmp}/${name}.err"; then
    echo "FAIL  ${name} (claude run errored; see ${_eval_tmp}/${name}.err)"
    _eval_failures=$((_eval_failures + 1))
    return
  fi
  if ! run_cli "${fixture}" "${out}"; then
    _eval_failures=$((_eval_failures + 1))
  fi
}

# Visit every committed fixture in sorted order, calling `${1} <name> <fixture-path>` for each. Reads the
# fixture list from FD 3, NOT stdin, so an inner command that consumes stdin (claude -p and tsx both do)
# can no longer swallow the remaining names and truncate the loop after the first fixture (#1387).
for_each_fixture() {
  local fn="$1" name fixture
  while IFS= read -r name <&3; do
    fixture="$(fixture_path_for "${name}")"
    "${fn}" "${name}" "${fixture}"
  done 3< <(list_fixtures)
}

# Dispatch <callback> over either ALL fixtures (no name) or exactly ONE named fixture (#1397). Validation
# only when a name is given: an unknown name is a usage error (exit 2, listing what IS available), never a
# silent no-op and never a silent fall-through to running everything. Token-free by itself: it only picks
# which fixtures to hand the callback, which is score_one_fixture in the real run (that one spends) and a
# recorder in the test (which does not), so the selection logic is testable without a real claude call.
select_and_run() {
  local fn="$1" only="${2:-}"
  if [ -z "${only}" ]; then
    for_each_fixture "${fn}"
    return
  fi
  local fixture
  fixture="$(fixture_path_for "${only}")"
  if [ ! -f "${fixture}" ]; then
    echo "eval-prep-runbook: no such fixture '${only}'. Available:" >&2
    list_fixtures | sed 's/^/  /' >&2
    return 2
  fi
  "${fn}" "${only}" "${fixture}"
}

# $1 (optional): a single fixture name to eval instead of all of them (a cheap targeted recheck).
real_run() {
  local only="${1:-}"
  cost_warning
  command -v jq >/dev/null 2>&1 || { echo "eval-prep-runbook: jq is required" >&2; exit 1; }
  command -v tsx >/dev/null 2>&1 || command -v pnpm >/dev/null 2>&1 || { echo "eval-prep-runbook: tsx (or pnpm) is required to score output" >&2; exit 1; }

  # Reuse the SAME model pin and fail-closed tool scope the real runners use (mac/scripts/lib). The scope
  # here is deliberately tighter than prep's: only Read is pre-approved and, under --permission-mode
  # manual, web access and every other tool are denied, so the run must reason from the inline sources.
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/mac/scripts/lib/models.sh"
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/mac/scripts/lib/claude-run-scope.sh"
  _eval_scope="$(claude_run_scope "Read" "manual" "Bash Edit WebFetch WebSearch Skill" "eval-prep-runbook")" || {
    echo "eval-prep-runbook: refusing to run, unsafe tool scope" >&2
    exit 1
  }

  _eval_claude="$(command -v claude || true)"
  [ -n "${_eval_claude}" ] || { echo "eval-prep-runbook: the 'claude' CLI is not on PATH" >&2; exit 1; }

  _eval_tmp="$(mktemp -d)"
  trap 'rm -rf "${_eval_tmp}"' EXIT

  _eval_failures=0
  _eval_total=0
  select_and_run score_one_fixture "${only}" || return $?

  echo
  echo "eval complete: $(( _eval_total - _eval_failures ))/${_eval_total} fixtures passed"
  [ "${_eval_failures}" -eq 0 ]
}

# One place that runs the TS scorer, whether directly (tsx on PATH) or through pnpm.
run_cli() {
  if command -v tsx >/dev/null 2>&1; then
    tsx "${CLI}" "$@"
  else
    ( cd "${REPO_ROOT}" && pnpm exec tsx "${CLI}" "$@" )
  fi
}

main() {
  case "${1:-}" in
    ""|-h|--help)
      usage
      cost_warning
      ;;
    --list)
      list_fixtures
      ;;
    --self-check)
      run_cli --self-check
      ;;
    --dry-run)
      [ -n "${2:-}" ] || { echo "usage: eval-prep-runbook.sh --dry-run <fixture-name>" >&2; exit 2; }
      command -v jq >/dev/null 2>&1 || { echo "eval-prep-runbook: jq is required for --dry-run" >&2; exit 1; }
      build_prompt "$(fixture_path_for "$2")"
      ;;
    --yes)
      real_run "${2:-}"
      ;;
    *)
      echo "eval-prep-runbook: unknown option '$1'" >&2
      usage
      exit 2
      ;;
  esac
}

# Source guard (#1387): a pure-shell test sources this file to exercise for_each_fixture directly, without
# running the real, token-spending eval. Only run main when executed, never when sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
