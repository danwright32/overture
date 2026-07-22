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

usage() {
  echo "Usage: $(basename "$0") <pr-number>" >&2
  exit 1
}

# Classifies one check-run row (the tab-separated fields produced by the check-runs
# query in main) and prints its status line. Mutates the caller's EXIT_CODE, same as
# when this was the inline body of the loop below.
classify_check_run() {
  local name="$1" status="$2" conclusion="$3"
  local label

  if [[ "${status}" == "completed" ]]; then
    case "${conclusion}" in
      success)
        label="Passed"
        ;;
      failure)
        label="Failed"
        EXIT_CODE=1
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

  while IFS=$'\t' read -r name status conclusion; do
    classify_check_run "${name}" "${status}" "${conclusion}"
  done <<< "${CHECK_RUNS}"

  echo
  if [[ ${EXIT_CODE} -eq 0 ]]; then
    echo "All checks have actually passed. Safe to merge on CI grounds."
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
