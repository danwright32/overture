#!/usr/bin/env bash
set -euo pipefail

# Waits for a PR's CI to actually pass, via check-pr-ci.sh, then merges it. Never merges on
# the strength of "hasn't failed yet": only a genuine pass from check-pr-ci.sh triggers the
# merge. Stops, without merging, on a genuine failure, a stalled check, or a timeout.
#
# Usage: scripts/merge-when-green.sh <pr-number> [max-wait-seconds]

REPO="danwright32/overture"
GH_IDENTITY="danwright32"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL_INTERVAL_SECONDS=15
DEFAULT_MAX_WAIT_SECONDS=900

usage() {
  echo "Usage: $(basename "$0") <pr-number> [max-wait-seconds]" >&2
  exit 1
}

[[ $# -eq 1 || $# -eq 2 ]] || usage
PR_NUMBER="$1"
[[ "${PR_NUMBER}" =~ ^[0-9]+$ ]] || usage
MAX_WAIT_SECONDS="${2:-${DEFAULT_MAX_WAIT_SECONDS}}"

gh_as_danwright32() {
  GH_TOKEN="$(gh auth token -u "${GH_IDENTITY}")" gh "$@"
}

START="$(date -u +%s)"

while true; do
  if OUTPUT="$("${SCRIPT_DIR}/check-pr-ci.sh" "${PR_NUMBER}" 2>&1)"; then
    CODE=0
  else
    CODE=$?
  fi
  echo "${OUTPUT}"

  if [[ ${CODE} -eq 0 ]]; then
    echo
    echo "CI genuinely passed. Merging PR #${PR_NUMBER}..."
    gh_as_danwright32 pr merge "${PR_NUMBER}" -R "${REPO}" --squash --delete-branch
    exit 0
  fi

  if grep -q "Stalled" <<< "${OUTPUT}"; then
    echo
    echo "Stopped: a check is stalled. Not merging. Fix the runner, then rerun this script." >&2
    exit 1
  fi

  if grep -qE ": Failed" <<< "${OUTPUT}"; then
    echo
    echo "Stopped: a check genuinely failed. Not merging." >&2
    exit 1
  fi

  NOW="$(date -u +%s)"
  ELAPSED=$(( NOW - START ))
  if [[ ${ELAPSED} -ge ${MAX_WAIT_SECONDS} ]]; then
    echo
    echo "Stopped: still not resolved after ${MAX_WAIT_SECONDS}s. Not merging. Rerun to keep waiting." >&2
    exit 1
  fi

  echo "Still waiting (${ELAPSED}s elapsed)... rechecking in ${POLL_INTERVAL_SECONDS}s"
  sleep "${POLL_INTERVAL_SECONDS}"
done
