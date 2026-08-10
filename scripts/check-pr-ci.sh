#!/usr/bin/env bash
set -euo pipefail

# Reports the real state of every check on a PR, one line per check run. Part of #478
# (milestone 12), Phase 4 (#506).
#
# This script once built a "stalled" vs "queued" distinction for the swift-tests check, the
# only job that ran on a self-hosted runner (which could leave a job pending forever with no
# signal that its runner had died). #1347 retired that runner and #1352 removed the stall
# machinery. The only check left is typecheck-and-test on GitHub-hosted ubuntu-latest, whose
# availability GitHub itself guarantees, so a bare "Pending" (which blocks the merge) is the
# honest report: there is no longer any runner that could silently swallow a job forever.
#
# Usage: scripts/check-pr-ci.sh <pr-number>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ci-config.sh"

# #2199: the exit code that means "GitHub never ran this", as a named constant shared by this script
# and merge-when-green.sh, so the two cannot disagree about what it means.
RUNNER_NEVER_STARTED_EXIT=2

# Did a machine ever pick this check up? An Actions job that was never assigned has an empty
# `runner_name` AND an empty `steps` array; a job that ran and failed has both. Asked only on the
# failure path, so the ordinary green run makes no extra API calls.
#
# Fails towards "it was assigned", so an API hiccup here can only ever report the ordinary red, never
# invent an infrastructure excuse for a genuine test failure.
runner_was_assigned() {
  local check_name="$1" run_id jobs
  run_id="$(gh_as_danwright32 run list -R "${REPO}" --commit "${SHA}" --limit 1 \
    --json databaseId --jq '.[0].databaseId' 2>/dev/null)" || return 0
  [[ -n "${run_id}" ]] || return 0
  jobs="$(gh_as_danwright32 api "repos/${REPO}/actions/runs/${run_id}/jobs" \
    --jq ".jobs[] | select(.name == \"${check_name}\") | [(.runner_name // \"\"), (.steps | length)] | @tsv" \
    2>/dev/null)" || return 0
  [[ -n "${jobs}" ]] || return 0
  local runner steps
  IFS=$'\t' read -r runner steps <<< "${jobs}"
  [[ -n "${runner}" || "${steps:-0}" -gt 0 ]]
}

usage() {
  echo "Usage: $(basename "$0") <pr-number>" >&2
  exit 1
}

# Classifies one check-run row (the tab-separated fields produced by the check-runs
# query in main) and prints its status line. Mutates the caller's EXIT_CODE, same as
# when this was the inline body of the loop below.
# #2199: `never_started` is "1" when this check concluded WITHOUT a runner ever being assigned,
# which main works out from the Actions job behind it. Passed in rather than looked up here, so this
# stays a pure classifier its fixtures can drive.
classify_check_run() {
  local name="$1" status="$2" conclusion="$3" never_started="${4:-}"
  local label

  if [[ "${status}" == "completed" ]]; then
    case "${conclusion}" in
      success)
        label="Passed"
        ;;
      failure)
        # #2199: a red that no machine ever picked up is not a failing test. On 2026-08-06 GitHub
        # Actions had an outage, PR #2194's only check sat queued and came back red, and about thirty
        # minutes went into establishing that the code was never involved. The signal is unambiguous
        # once looked for (no runner name, no steps), and reading one as the other sends whoever sees
        # it hunting a bug that does not exist. Same distinction as #1006's "the process died" versus
        # "a test failed", one layer out.
        if [[ "${never_started}" == "1" ]]; then
          label="Never started: no runner was ever assigned, so nothing ran. This is GitHub, not your code."
          RUNNER_NEVER_STARTED=1
          EXIT_CODE=1
        else
          label="Failed"
          EXIT_CODE=1
        fi
        ;;
      skipped)
        # typecheck-and-test runs unconditionally (no path filter in ci.yml), so nothing is
        # supposed to skip it. A skip is therefore unexpected and blocks the merge. Reported as
        # "Skipped", never folded into "Passed": this whole script exists so Dan can tell a check
        # that actually ran and went green apart from one that never ran at all.
        label="Skipped unexpectedly (nothing should skip this check)"
        EXIT_CODE=1
        ;;
      *)
        label="${conclusion}"
        EXIT_CODE=1
        ;;
    esac
    echo "${name}: ${label}"
    return
  fi

  # Not completed: still pending. The only check runs on GitHub-hosted ubuntu-latest, whose
  # availability GitHub guarantees, so a bare "Pending" (which blocks the merge) is the honest
  # report. There is no longer a self-hosted runner that could silently swallow a job forever,
  # so there is no "stalled" distinction left to draw.
  echo "${name}: Pending"
  EXIT_CODE=1
}

# check_mergeable <mergeable-value>. #625: GitHub never runs CI checks on a PR it can't merge,
# so polling check-runs for one just times out reporting "No checks found yet" for the whole
# poll window instead of surfacing the real, fixable problem (a merge conflict). Only
# CONFLICTING is a hard stop; UNKNOWN (mergeability not computed yet, e.g. moments after a push)
# is not a conflict and must fall through to the normal check-runs poll.
check_mergeable() {
  local mergeable="$1"
  if [[ "${mergeable}" == "CONFLICTING" ]]; then
    echo "Unmergeable: PR #${PR_NUMBER} has a merge conflict against its base branch. GitHub never runs CI checks on a PR it can't merge, so waiting here would just time out. Resolve the conflict, then rerun."
    return 1
  fi
  return 0
}

main() {
  [[ $# -eq 1 ]] || usage
  PR_NUMBER="$1"
  [[ "${PR_NUMBER}" =~ ^[0-9]+$ ]] || usage

  command -v gh >/dev/null || { echo "gh CLI not found; install it and run: gh auth login" >&2; exit 1; }

  # One combined field fetch instead of two round trips (see the CHECK_RUNS @tsv fetch below for
  # the same pattern already used in this file).
  PR_INFO="$(gh_as_danwright32 pr view "${PR_NUMBER}" -R "${REPO}" --json headRefOid,mergeable --jq '[.headRefOid, .mergeable] | @tsv')"
  IFS=$'\t' read -r SHA MERGEABLE <<< "${PR_INFO}"
  if [[ -z "${SHA}" || "${SHA}" == "null" ]]; then
    echo "Error: could not resolve a head commit for PR #${PR_NUMBER} on ${REPO}." >&2
    exit 1
  fi

  echo "PR #${PR_NUMBER} on ${REPO}, commit ${SHA:0:7}"
  echo

  check_mergeable "${MERGEABLE}" || exit 1

  # conclusion is last because it is null (empty after //) until a check completes, and
  # bash's `read` with a tab IFS collapses an empty middle field, shifting a later field
  # into the wrong slot. An empty trailing field does not have that problem.
  CHECK_RUNS="$(gh_as_danwright32 api "repos/${REPO}/commits/${SHA}/check-runs" \
    --jq '.check_runs[] | [.name, .status, .conclusion // ""] | @tsv')"

  if [[ -z "${CHECK_RUNS}" ]]; then
    echo "No checks found yet for this commit." >&2
    exit 1
  fi

  EXIT_CODE=0
  RUNNER_NEVER_STARTED=0

  while IFS=$'\t' read -r name status conclusion; do
    local never_started=""
    if [[ "${status}" == "completed" && "${conclusion}" == "failure" ]] \
       && ! runner_was_assigned "${name}"; then
      never_started=1
    fi
    classify_check_run "${name}" "${status}" "${conclusion}" "${never_started}"
  done <<< "${CHECK_RUNS}"

  echo
  if [[ ${EXIT_CODE} -eq 0 ]]; then
    echo "All checks have actually passed. Safe to merge on CI grounds."
  elif [[ ${RUNNER_NEVER_STARTED} -eq 1 ]]; then
    # #2199: its OWN exit code, so a caller can tell infrastructure from a real red without parsing
    # the words. Still never zero: nothing has passed, so nothing may merge on it.
    echo "A check went red without ever being picked up by a runner. Nothing ran, so there is no"
    echo "failure to investigate: re-run it with"
    echo "  gh run rerun --failed -R ${REPO} \$(gh run list -R ${REPO} --commit ${SHA} --limit 1 --json databaseId --jq '.[0].databaseId')"
    exit "${RUNNER_NEVER_STARTED_EXIT}"
  else
    echo "Not every check has actually passed yet. Do not merge on the strength of pending or no failure yet alone."
  fi

  exit "${EXIT_CODE}"
}

# Allow this file to be sourced (e.g. by check-pr-ci.test.sh) without running main,
# so the classification logic can be exercised directly against stubbed gh responses.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
