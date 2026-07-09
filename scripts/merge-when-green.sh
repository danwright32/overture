#!/usr/bin/env bash
set -euo pipefail

# Waits for a PR's CI to actually pass, via check-pr-ci.sh, then merges it. Never merges on
# the strength of "hasn't failed yet": only a genuine pass from check-pr-ci.sh triggers the
# merge. Stops, without merging, on a genuine failure, a stalled check, an unmergeable PR, or
# a timeout.
#
# Usage: scripts/merge-when-green.sh <pr-number> [max-wait-seconds]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ci-config.sh"

POLL_INTERVAL_SECONDS=15
DEFAULT_MAX_WAIT_SECONDS=900

usage() {
  echo "Usage: $(basename "$0") <pr-number> [max-wait-seconds]" >&2
  exit 1
}

# classify_stop_reason <check-pr-ci.sh output>. Decides whether to stop polling and why, or
# prints nothing to mean "keep polling". Extracted so this decision is testable without
# spinning up gh or a real check-pr-ci.sh run.
#
# #625: a PR with a real merge conflict never gets CI checks run on it at all, so without the
# "conflict" case, check-pr-ci.sh's "No checks found yet" would just repeat every poll until
# MAX_WAIT_SECONDS instead of surfacing the real, fixable problem (a merge conflict) right away.
classify_stop_reason() {
  local output="$1"
  if grep -q "^Unmergeable:" <<< "${output}"; then
    echo "conflict"
    return
  fi
  if grep -q "Stalled" <<< "${output}"; then
    echo "stalled"
    return
  fi
  if grep -qE ": Failed" <<< "${output}"; then
    echo "failed"
    return
  fi
}

main() {
  [[ $# -eq 1 || $# -eq 2 ]] || usage
  PR_NUMBER="$1"
  [[ "${PR_NUMBER}" =~ ^[0-9]+$ ]] || usage
  MAX_WAIT_SECONDS="${2:-${DEFAULT_MAX_WAIT_SECONDS}}"

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

    case "$(classify_stop_reason "${OUTPUT}")" in
      conflict)
        echo
        echo "Stopped: PR #${PR_NUMBER} has a merge conflict, so CI checks will never appear. Not merging. Resolve the conflict, then rerun this script." >&2
        exit 1
        ;;
      stalled)
        echo
        echo "Stopped: a check is stalled. Not merging. Fix the runner, then rerun this script." >&2
        exit 1
        ;;
      failed)
        echo
        echo "Stopped: a check genuinely failed. Not merging." >&2
        exit 1
        ;;
    esac

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
}

# Allow this file to be sourced (e.g. by a test fixture) without running main, so
# classify_stop_reason can be exercised directly. Mirrors check-pr-ci.sh's own convention.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
