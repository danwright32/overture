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

REPO="danwright32/overture"
GH_IDENTITY="danwright32"
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

[[ $# -eq 1 ]] || usage
PR_NUMBER="$1"
[[ "${PR_NUMBER}" =~ ^[0-9]+$ ]] || usage

command -v gh >/dev/null || { echo "gh CLI not found; install it and run: gh auth login" >&2; exit 1; }

gh_as_danwright32() {
  GH_TOKEN="$(gh auth token -u "${GH_IDENTITY}")" gh "$@"
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

SHA="$(gh_as_danwright32 pr view "${PR_NUMBER}" -R "${REPO}" --json headRefOid --jq .headRefOid)"
if [[ -z "${SHA}" || "${SHA}" == "null" ]]; then
  echo "Error: could not resolve a head commit for PR #${PR_NUMBER} on ${REPO}." >&2
  exit 1
fi

echo "PR #${PR_NUMBER} on ${REPO}, commit ${SHA:0:7}"
echo

# conclusion is last because it is null (empty after //) until a check completes, and
# bash's `read` with a tab IFS collapses an empty middle field, shifting started_at into
# conclusion's slot. An empty trailing field does not have that problem.
CHECK_RUNS="$(gh_as_danwright32 api "repos/${REPO}/commits/${SHA}/check-runs" \
  --jq '.check_runs[] | [.name, .status, .started_at // "", .conclusion // ""] | @tsv')"

if [[ -z "${CHECK_RUNS}" ]]; then
  echo "No checks found yet for this commit." >&2
  exit 1
fi

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

NOW="$(date -u +%s)"
EXIT_CODE=0

while IFS=$'\t' read -r name status started_at conclusion; do
  if [[ "${status}" == "completed" ]]; then
    case "${conclusion}" in
      success)
        label="Passed"
        ;;
      failure)
        label="Failed"
        EXIT_CODE=1
        ;;
      *)
        label="${conclusion}"
        EXIT_CODE=1
        ;;
    esac
    echo "${name}: ${label}"
    continue
  fi

  if [[ "${name}" != "${SWIFT_CHECK_NAME}" ]]; then
    echo "${name}: Pending"
    EXIT_CODE=1
    continue
  fi

  if [[ -z "${started_at}" ]]; then
    ELAPSED=0
  else
    ELAPSED=$(( NOW - $(to_epoch "${started_at}") ))
    [[ ${ELAPSED} -lt 0 ]] && ELAPSED=0
  fi
  DURATION="$(format_duration "${ELAPSED}")"
  EXIT_CODE=1

  if [[ ${ELAPSED} -lt ${STALL_THRESHOLD_SECONDS} ]]; then
    echo "${name}: Still working (pending ${DURATION})"
    continue
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
done <<< "${CHECK_RUNS}"

echo
if [[ ${EXIT_CODE} -eq 0 ]]; then
  echo "All checks have actually passed. Safe to merge on CI grounds."
else
  echo "Not every check has actually passed yet. Do not merge on the strength of pending or no failure yet alone."
fi

exit "${EXIT_CODE}"
