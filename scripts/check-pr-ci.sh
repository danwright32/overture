#!/usr/bin/env bash
set -euo pipefail

# Reports the real state of every check on a PR, one line per check run. Part of #478
# (milestone 12), Phase 4 (#506). GitHub's Checks API has no concept of "stalled" distinct
# from "queued": a job assigned to a dead self-hosted runner just sits pending forever with
# no differentiation from one that is seconds from finishing. This script builds that
# differentiation for the swift-tests check, the only job that runs on the self-hosted
# runner (typecheck-and-test runs on GitHub-hosted ubuntu-latest, which GitHub itself
# guarantees availability for, so a bare "Pending" is good enough for it).
#
# Usage: scripts/check-pr-ci.sh <pr-number>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ci-config.sh"

SWIFT_CHECK_NAME="swift-tests"
SWIFT_RUNNER_LABEL="overture-mac"

# swift-tests completed in 31s and 23s on its first two real invocations (Phase 3, #513).
# 300s is generous relative to that, roughly 10x the slower run, while staying in the low
# single-digit minutes the plan called for, so a normal run, or a slow but real ephemeral
# runner re-registration cycle, is never mistaken for a stall.
STALL_THRESHOLD_SECONDS=300

usage() {
  echo "Usage: $(basename "$0") <pr-number>" >&2
  exit 1
}

format_duration() {
  local total=$1
  local m=$((total / 60))
  local s=$((total % 60))
  if [[ ${m} -gt 0 ]]; then
    printf '%dm%ds' "${m}" "${s}"
  else
    printf '%ds' "${s}"
  fi
}

to_epoch() {
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s
}

RUNNER_STATUS=""
RUNNER_BUSY=""
RUNNER_CHECKED=0
fetch_runner_info() {
  [[ "${RUNNER_CHECKED}" -eq 1 ]] && return
  RUNNER_CHECKED=1
  local line
  FULL_OUTPUT="$(SWIFT_RUNNER_LABEL="${SWIFT_RUNNER_LABEL}" GH_TOKEN="$(gh auth token -u "${GH_IDENTITY}")" gh api "repos/${REPO}/actions/runners" \
    --jq '.runners[] | select(.labels[].name == env.SWIFT_RUNNER_LABEL) | [.status, .busy] | @tsv')"
  line="$(head -n1 <<< "${FULL_OUTPUT}")"
  if [[ -n "${line}" ]]; then
    IFS=$'\t' read -r RUNNER_STATUS RUNNER_BUSY <<< "${line}"
  fi
}

# A check run's own started_at is pickup time, populated only once a runner claims the
# job; it stays null the whole time a job sits queued, which is exactly the stalled case
# this script exists to catch. The job's created_at, one level down at
# actions/runs/{run_id}/jobs, is the true queue time. check_suite.id on the check run row
# is the correlation key back to the workflow run (workflow_runs[].check_suite_id), needed
# because a same repo PR fires both a push and a pull_request run for the same commit, so
# check_suite_id disambiguates which of the two the row actually belongs to.
resolve_queue_created_at() {
  local check_suite_id="$1"
  local run_lookup run_id
  run_lookup="$(CHECK_SUITE_ID="${check_suite_id}" GH_TOKEN="$(gh auth token -u "${GH_IDENTITY}")" gh api "repos/${REPO}/actions/runs?head_sha=${SHA}" \
    --jq '.workflow_runs[] | select(.check_suite_id == (env.CHECK_SUITE_ID | tonumber)) | .id')"
  run_id="$(head -n1 <<< "${run_lookup}")"
  if [[ -z "${run_id}" ]]; then
    return
  fi

  local job_lookup
  job_lookup="$(SWIFT_CHECK_NAME="${SWIFT_CHECK_NAME}" GH_TOKEN="$(gh auth token -u "${GH_IDENTITY}")" gh api "repos/${REPO}/actions/runs/${run_id}/jobs" \
    --jq '.jobs[] | select(.name == env.SWIFT_CHECK_NAME) | .created_at')"
  head -n1 <<< "${job_lookup}"
}

# Classifies one check-run row (the tab-separated fields produced by the check-runs
# query in main) and prints its status line. Mutates the caller's EXIT_CODE, same as
# when this was the inline body of the loop below.
classify_check_run() {
  local name="$1" status="$2" check_suite_id="$3" conclusion="$4"
  local label PENDING_SINCE ELAPSED DURATION

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
        # #761: swift-tests is path-filtered in ci.yml, so it legitimately does not run on a change
        # that touches no Swift, fixture or CI-script file (an npm dependency bump, say). That is an
        # INTENTIONAL decision, not an absent result, so it must not block the merge.
        #
        # Reported as "Skipped", never folded into "Passed": this whole script exists so Dan can tell
        # a check that actually ran and went green apart from one that never ran at all. Any OTHER
        # check skipping is unexpected and still blocks, because nothing is supposed to skip it.
        if [[ "${name}" == "${SWIFT_CHECK_NAME}" ]]; then
          label="Skipped (nothing Swift-related changed, so the Mac tests were not needed)"
        else
          label="Skipped unexpectedly (nothing should skip this check)"
          EXIT_CODE=1
        fi
        ;;
      *)
        label="${conclusion}"
        EXIT_CODE=1
        ;;
    esac
    echo "${name}: ${label}"
    return
  fi

  if [[ "${name}" != "${SWIFT_CHECK_NAME}" ]]; then
    echo "${name}: Pending"
    EXIT_CODE=1
    return
  fi

  EXIT_CODE=1
  PENDING_SINCE=""
  if [[ -n "${check_suite_id}" ]]; then
    PENDING_SINCE="$(resolve_queue_created_at "${check_suite_id}")"
  fi

  if [[ -z "${PENDING_SINCE}" ]]; then
    echo "${name}: Stalled. Could not determine how long this has been queued."
    return
  fi

  ELAPSED=$(( NOW - $(to_epoch "${PENDING_SINCE}") ))
  [[ ${ELAPSED} -lt 0 ]] && ELAPSED=0
  DURATION="$(format_duration "${ELAPSED}")"

  if [[ ${ELAPSED} -lt ${STALL_THRESHOLD_SECONDS} ]]; then
    echo "${name}: Still working (pending ${DURATION})"
    return
  fi

  fetch_runner_info

  if [[ -z "${RUNNER_STATUS}" ]]; then
    echo "${name}: Stalled. No self-hosted runner is currently registered (pending ${DURATION})."
  elif [[ "${RUNNER_STATUS}" != "online" ]]; then
    echo "${name}: Stalled. Runner appears unreachable, status is ${RUNNER_STATUS} (pending ${DURATION})."
  elif [[ "${RUNNER_BUSY}" != "true" ]]; then
    echo "${name}: Stalled. Runner is online but idle and has not picked up the job (pending ${DURATION})."
  else
    echo "${name}: Still working, longer than usual, but the runner is online and busy (pending ${DURATION})."
  fi
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
  # bash's `read` with a tab IFS collapses an empty middle field, shifting check_suite_id
  # into conclusion's slot. An empty trailing field does not have that problem.
  CHECK_RUNS="$(gh_as_danwright32 api "repos/${REPO}/commits/${SHA}/check-runs" \
    --jq '.check_runs[] | [.name, .status, .check_suite.id // "", .conclusion // ""] | @tsv')"

  if [[ -z "${CHECK_RUNS}" ]]; then
    echo "No checks found yet for this commit." >&2
    exit 1
  fi

  NOW="$(date -u +%s)"
  EXIT_CODE=0

  while IFS=$'\t' read -r name status check_suite_id conclusion; do
    classify_check_run "${name}" "${status}" "${check_suite_id}" "${conclusion}"
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
