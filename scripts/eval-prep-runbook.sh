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
# MODEL: defaults to the drafting model this run really uses. Override with OVERTURE_EVAL_MODEL to score
# a DIFFERENT tier against the same fixtures, which is how the question "would sonnet or haiku still obey
# the strict contact rules" gets answered with evidence instead of opinion. Deliberately its own variable
# rather than a default on OVERTURE_MODEL_DRAFTING: that one is pinned on purpose (see models.sh), and
# making it env-overridable would let a stray variable quietly change what writes Dan's real emails.
#
# Usage:
#   scripts/eval-prep-runbook.sh                 # show this help and the cost warning; spends nothing
#   scripts/eval-prep-runbook.sh --list          # list the fixtures; spends nothing
#   scripts/eval-prep-runbook.sh --self-check    # score each fixture's own compliant sample; spends nothing
#   scripts/eval-prep-runbook.sh --dry-run NAME  # print the prompt for one fixture; spends nothing
#   scripts/eval-prep-runbook.sh --yes           # RUN THE REAL EVAL against every fixture; SPENDS TOKENS
#   scripts/eval-prep-runbook.sh --yes NAME      # RUN THE REAL EVAL against ONE fixture; SPENDS TOKENS
#   scripts/eval-prep-runbook.sh --yes --failed  # RE-RUN only the fixtures the last run FAILED; SPENDS TOKENS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURE_DIR="${REPO_ROOT}/fixtures/prep-eval"
RUNBOOK="${REPO_ROOT}/docs/prep-runbook.md"
CLI="${SCRIPT_DIR}/eval-prep-runbook.ts"
# Where the last real run records which fixtures it left FAILING, so `--yes --failed` can recheck only
# those (#1400). Gitignored; overridable so the test can point it at a throwaway path. NOT under the
# per-run mktemp dir (that is deleted on EXIT), because it must survive between invocations.
FAILURES_FILE="${OVERTURE_EVAL_FAILURES_FILE:-${REPO_ROOT}/.overture-eval-failures}"
# Where each real run's produced outputs are KEPT (#1870). A run spends real money to produce them, so
# deleting them on exit means a failure can be named and never read: the one FAIL of the 2026-07-31 run
# reported which expectation missed and left nothing to tell a rule that had drifted from an expectation
# that was simply too strict. Reading it back had to cost another run.
#
# Kept per run in a dated directory and pruned to the last few, the same shape as the store backups:
# evidence that grows without limit is its own problem, and only the recent handful is ever read.
# Gitignored, and overridable so the test can point it at a throwaway path.
RUNS_DIR="${OVERTURE_EVAL_RUNS_DIR:-${REPO_ROOT}/.overture-eval-runs}"
RUNS_KEPT=10
# #1867: the record of the last run that GENUINELY COMPLETED, read at push time by
# scripts/check-prep-eval-freshness.sh to warn when the runbook has changed since. The record's
# shape, its path and the fingerprint all live in one file shared with that reader, so a change to
# what is written cannot leave the reader looking for something else.
# shellcheck source=./lib/prep-eval-record.sh
. "${SCRIPT_DIR}/lib/prep-eval-record.sh"
LAST_RUN_FILE="$(prep_eval_last_run_file "${REPO_ROOT}")"

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
# The results version the run is asked to write, DERIVED from the committed contract fixtures rather than
# typed here (#1868, L41: a list that must mirror another source of truth is derived from it, never
# maintained by hand beside it).
#
# It was hard-coded as 6, and the runbook has since required fields that exist only from version 8 (a
# `showSummary` since #1824). So an obedient run produced a v6 document carrying a v8 field, the scorer
# rejected it on shape before scoring any judgment, and 11 of 13 fixtures failed for a reason that had
# nothing to do with the runbook. The tokens were spent all the same.
results_contract_version() {
  ls "${REPO_ROOT}/fixtures/prep-results" \
    | sed -n 's/^v\([0-9][0-9]*\)\.json$/\1/p' \
    | sort -n | tail -1
}

build_prompt() {
  local fixture="$1"
  local input sources houses
  input="$(jq '.input' "${fixture}")"
  sources="$(jq -r '.sources[] | "- \(.label) (\(.url // "no url")):\n\(.content)\n"' "${fixture}")"
  # #1723: the run-level house list, when the fixture carries one. Without this the fixture's `houses`
  # would sit in the file unread and its test would pass by accident, which is the exact vacuous-pass this
  # eval exists to avoid. Absent on every fixture that predates the field, and absent from the prompt then,
  # which is a real state the runbook has a documented fallback for.
  houses="$(jq -r 'if .houses then "\nHouses named by the app (the run-level `houses` list from the work-list file):\n" + (.houses | tojson) else "" end' "${fixture}")"
  cat <<PROMPT
You are running a REGRESSION EVAL of the Overture Prep runbook. Apply the rules in the runbook below to
the SINGLE work-list item, then output ONLY the resulting PrepResults JSON (version $(results_contract_version)) for that one item
and nothing else (no prose, no code fence needed).

IMPORTANT: research ONLY from the "Sources" provided here. Do NOT fetch the web or use any tool; all the
material you are permitted to use is inline below. This keeps the eval reproducible and free of real PII.
Copy the item's naturalKey byte for byte into the result.

Work-list item:
${input}
${houses}
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
# See the MODEL note in the header: a dedicated override, so production drafting stays pinned.
_eval_model="${OVERTURE_EVAL_MODEL:-${OVERTURE_MODEL_DRAFTING:-opus}}"
_eval_tmp=""
_eval_failures=0
_eval_total=0
# Newline-separated names of the fixtures this run actually RAN and the subset that FAILED, so the run can
# rewrite FAILURES_FILE afterward (#1400). Newline strings, not bash arrays, because macOS ships bash 3.2
# where an empty array under `set -u` is an "unbound variable" error.
_eval_ran_names=""
_eval_failed_names=""

# Score ONE fixture: run the drafter on it, then check the output. A malformed or errored AI run counts
# as that fixture failing and never aborts the rest. claude's stdin is /dev/null so it can neither block
# on nor (with the FD-3 loop below) truncate the fixture list.
score_one_fixture() {
  local name="$1" fixture="$2" prompt out
  _eval_total=$((_eval_total + 1))
  _eval_ran_names="${_eval_ran_names}${name}"$'\n'
  echo "==> ${name}: running claude..."
  prompt="$(build_prompt "${fixture}")"
  out="${_eval_tmp}/${name}.out"
  # shellcheck disable=SC2086  # $_eval_scope MUST word-split into --allowedTools <list> --permission-mode <mode>
  if ! "${_eval_claude}" -p "${prompt}" --model "${_eval_model}" ${_eval_scope} </dev/null > "${out}" 2>"${_eval_tmp}/${name}.err"; then
    echo "FAIL  ${name} (claude run errored; see ${_eval_tmp}/${name}.err)"
    _eval_failures=$((_eval_failures + 1))
    _eval_failed_names="${_eval_failed_names}${name}"$'\n'
    return
  fi
  if ! run_cli "${fixture}" "${out}"; then
    _eval_failures=$((_eval_failures + 1))
    _eval_failed_names="${_eval_failed_names}${name}"$'\n'
  fi
}

# Dispatch <callback> over a newline-separated list of fixture NAMES, calling `<fn> <name> <path>` for each.
# Reads the list from FD 3, NOT stdin, so an inner command that consumes stdin (claude -p and tsx both do)
# can no longer swallow the remaining names and truncate the loop after the first fixture (#1387). Token-free
# by itself; the callback is score_one_fixture in a real run (that one spends) and a recorder in the test.
for_each_in_list() {
  local fn="$1" names="$2" name
  while IFS= read -r name <&3; do
    [ -n "${name}" ] || continue
    "${fn}" "${name}" "$(fixture_path_for "${name}")"
  done 3< <(printf '%s\n' "${names}")
}

# Visit every committed fixture in sorted order.
for_each_fixture() {
  for_each_in_list "$1" "$(list_fixtures)"
}

# The fixture names the LAST real run left failing, one per line (empty if none / no run yet).
read_failures() {
  [ -f "${FAILURES_FILE}" ] || return 0
  grep -v '^$' -- "${FAILURES_FILE}" 2>/dev/null || true
}

# Resolve WHICH fixtures a real run would score, as a newline list on stdout, WITHOUT running or spending
# anything. `real_run` calls this FIRST, so a no-op selection returns 2 (with a message on stderr) and the
# caller bails as a free usage error BEFORE the SPENDS-TOKENS warning and any setup, meaning that warning is
# only ever printed when a real run is actually about to happen. Single source of the selection rules across
# the full run, a single named fixture (#1397), and --failed (#1400); never a silent fall-through to all.
run_plan() {
  local only="${1:-}" names kept="" n
  case "${only}" in
    "")
      list_fixtures
      ;;
    --failed)
      names="$(read_failures)"
      if [ -z "${names}" ]; then
        echo "eval-prep-runbook: no recorded failures from a previous --yes run to recheck." >&2
        return 2
      fi
      while IFS= read -r n; do
        [ -n "${n}" ] || continue
        if [ -f "$(fixture_path_for "${n}")" ]; then
          kept="${kept}${n}"$'\n'
        else
          echo "eval-prep-runbook: recorded failure '${n}' is no longer a fixture, skipping." >&2
        fi
      done <<< "${names}"
      if [ -z "${kept}" ]; then
        echo "eval-prep-runbook: no recorded failures still exist as fixtures to recheck." >&2
        return 2
      fi
      printf '%s' "${kept}"
      ;;
    *)
      if [ -f "$(fixture_path_for "${only}")" ]; then
        echo "${only}"
      else
        echo "eval-prep-runbook: no such fixture '${only}'. Available:" >&2
        list_fixtures | sed 's/^/  /' >&2
        return 2
      fi
      ;;
  esac
}

# Keep only the most recent RUNS_KEPT run directories (#1870). Only the plain dated shape is counted, so a
# directory a person renamed to hold on to (an eval worth keeping past its turn) can never be aged out by
# the next ten runs, which is the same rule the store backups follow for a `.foreign` snapshot.
prune_kept_runs() {
  [ -d "${RUNS_DIR}" ] || return 0
  local names count excess name
  names="$(ls -1 "${RUNS_DIR}" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort || true)"
  count="$(printf '%s\n' "${names}" | grep -c . || true)"
  excess=$(( count - RUNS_KEPT ))
  [ "${excess}" -gt 0 ] || return 0
  # Oldest first, so the ones removed are always the ones nobody is going to open.
  for name in $(printf '%s\n' "${names}" | sed -n "1,${excess}p"); do
    rm -rf "${RUNS_DIR:?}/${name}"
  done
}

# Rewrite FAILURES_FILE to the post-run failing set so `--yes --failed` CONVERGES (#1400): keep prior
# failures this run did NOT retest, drop the ones it retested-and-passed, add the ones it failed. This one
# rule is correct for a full run (nothing prior survives, so the file becomes exactly this run's failures),
# a single-fixture run, and a --failed rerun alike, so a targeted recheck can't silently forget the
# failures it didn't touch. Reads _eval_ran_names / _eval_failed_names (set by score_one_fixture).
update_failures_file() {
  local prior n kept=""
  prior="$(read_failures)"
  while IFS= read -r n; do
    [ -n "${n}" ] || continue
    grep -qxF -- "${n}" <<< "${_eval_ran_names}" && continue   # retested this run: its fresh verdict wins
    kept="${kept}${n}"$'\n'                                    # not retested: carry the prior failure forward
  done <<< "${prior}"
  # `grep -v '^$'` exits 1 on empty input, which under `set -e`/`pipefail` would abort a fully-passing run
  # (kept and failures both empty) right before the summary; `|| true` tolerates it. sort -u newline-
  # terminates every line so a later run_plan/for_each_in_list `read` loop never drops the last one.
  { printf '%s%s' "${kept}" "${_eval_failed_names}" | grep -v '^$' || true; } | sort -u > "${FAILURES_FILE}"
}

# Record that a run FINISHED, for scripts/check-prep-eval-freshness.sh to read at push time (#1867).
#
# Called ONLY after the last fixture in the plan has been scored. Nothing else in this script can serve
# as that record: the run directory above is created before the first claude call, so a run killed at
# that call leaves one indistinguishable from a finished run's, and the failures file is rewritten on a
# schedule of its own. A record a dead run can write is worse than none, because the warning it silences
# is the one worth reading.
#
# $1 is the fingerprint of the runbook this run STARTED against. An empty one means the text could not be
# read, so nothing is written and the previous record stands: this script may not claim a runbook it
# cannot name was evaluated.
record_completed_run() {
  local fingerprint="$1"
  if [ -z "${fingerprint}" ]; then
    echo "note: no freshness record written for this run (the runbook could not be fingerprinted)." >&2
    echo "scripts/check-prep-eval-freshness.sh will keep reporting whatever it reported before." >&2
    return 0
  fi
  local covered_names covered_passed
  covered_names="$(merged_covered_names "${fingerprint}")"
  covered_passed="$(covered_passing_count "${covered_names}")"
  prep_eval_write_last_run "${LAST_RUN_FILE}" "${fingerprint}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${_eval_total}" "$(list_fixtures | wc -l | tr -d ' ')" "$(( _eval_total - _eval_failures ))" \
    "${_eval_tmp}" "${covered_names}" "${covered_passed}"
  echo "recorded this completed run in ${LAST_RUN_FILE}"
}

# #2581: the fixtures scored against THIS runbook text, this run's plus whatever the previous record
# already held for the same text.
#
# Gated on the FINGERPRINT, and that gate is the whole of why this is safe. Carrying a verdict forward
# across a runbook edit would present a score taken against wording the current rules never saw as a
# score on the current rules, which is the overclaim this record exists to prevent. On any mismatch, or
# an unreadable record, or a record written before these fields existed, the answer is just this run,
# which is the behaviour every record had before and under-reports rather than over-reports.
merged_covered_names() {
  local fingerprint="$1" prior_fingerprint prior_names=""
  prior_fingerprint="$(prep_eval_record_field "${LAST_RUN_FILE}" runbook || true)"
  if [ -n "${fingerprint}" ] && [ "${prior_fingerprint}" = "${fingerprint}" ]; then
    prior_names="$(prep_eval_record_field "${LAST_RUN_FILE}" coveredNames || true)"
  fi
  # A union over NAMES, so re-scoring a fixture already covered adds nothing. `|| true` because grep
  # exits 1 on empty input, which under `set -e` would abort the run right before its summary.
  { printf '%s\n%s\n' "$(printf '%s' "${prior_names}" | tr ' ' '\n')" "${_eval_ran_names}" \
      | grep -v '^$' || true; } | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

# How many of the covered fixtures are currently PASSING, read off the same converging failures file
# `--yes --failed` reads, so the record and the recheck can never disagree about what is outstanding
# (L16). Called AFTER update_failures_file, which is what makes that file this run's answer rather than
# the previous one's.
covered_passing_count() {
  local covered_names="$1" failing=0 name
  for name in ${covered_names}; do
    grep -qxF -- "${name}" "${FAILURES_FILE}" 2>/dev/null && failing=$(( failing + 1 ))
  done
  echo $(( $(printf '%s' "${covered_names}" | tr ' ' '\n' | grep -c . || true) - failing ))
}

# $1 (optional): a single fixture name to eval instead of all of them (a cheap targeted recheck), or the
# literal "--failed" to recheck only the fixtures the previous real run left failing (#1400).
real_run() {
  local only="${1:-}" plan runbook_fingerprint
  # Resolve the run set FIRST. A no-op selection (unknown name, or --failed with nothing left to recheck)
  # bails here as a free usage error BEFORE the SPENDS-TOKENS warning and any dependency setup, so the
  # warning only ever appears when a real run is actually about to spend (#1400 follow-up).
  plan="$(run_plan "${only}")" || return $?

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
  # Resolved BEFORE the scope call, which needs it: `claude_run_scope`'s fifth argument is the binary it
  # enumerates this Mac's plugins with, so it can turn them off (#1682). Passing four arguments aborted the
  # helper under `set -u`, and its failure read as an unsafe scope, so this whole opt-in layer could not
  # start for three days (#1862).
  _eval_claude="$(command -v claude || true)"
  [ -n "${_eval_claude}" ] || { echo "eval-prep-runbook: the 'claude' CLI is not on PATH" >&2; exit 1; }

  _eval_scope="$(claude_run_scope "Read" "manual" "Bash Edit WebFetch WebSearch Skill" "eval-prep-runbook" \
                                  "${_eval_claude}")" || {
    # The helper has already said WHICH posture it refused, on stderr. This line names the stage, so a
    # caller-side failure (the shape #1862 took) is not read as the guard rejecting a real scope problem.
    echo "eval-prep-runbook: refusing to run: the tool scope for this run could not be established" >&2
    exit 1
  }

  # #1870: a real directory that OUTLIVES the run, not a mktemp deleted on exit. The stamp is the run's
  # own start time, so two runs never share a directory and the newest sorts last.
  _eval_tmp="${RUNS_DIR}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${_eval_tmp}"
  echo "keeping this run's outputs in ${_eval_tmp}"

  # #1867: the runbook text this run is about to score, captured BEFORE the first fixture and written
  # out only after the last one. Captured at the start on purpose: a runbook edited mid-run leaves the
  # record naming the text the run began with, so afterwards the check reads STALE, which is true, since
  # the later fixtures were scored against wording the earlier ones never saw.
  runbook_fingerprint="$(prep_eval_runbook_fingerprint "${RUNBOOK}" || true)"

  _eval_failures=0
  _eval_total=0
  _eval_ran_names=""
  _eval_failed_names=""
  for_each_in_list score_one_fixture "${plan}"

  # Record which fixtures this run left failing so a later `--yes --failed` can recheck just those.
  update_failures_file

  record_completed_run "${runbook_fingerprint}"

  prune_kept_runs

  echo
  echo "eval complete: $(( _eval_total - _eval_failures ))/${_eval_total} fixtures passed"
  echo "the outputs each fixture produced are in ${_eval_tmp}"
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
