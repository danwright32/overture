#!/usr/bin/env bash
set -euo pipefail

# Waits for a PR's CI to actually pass, via check-pr-ci.sh, then merges it. Never merges on
# the strength of "hasn't failed yet": only a genuine pass from check-pr-ci.sh triggers the
# merge. Stops, without merging, on a genuine failure, a stalled check, an unmergeable PR, or
# a timeout.
#
# #1006: also refuses to land on a RED base branch. A PR passing on its own branch says nothing
# about the branch it is about to join, and merging a second change onto a broken main makes it
# impossible to tell which change broke it. Overridable, because the fix for a red main has to be
# able to land.
#
# Usage: scripts/merge-when-green.sh <pr-number> [max-wait-seconds] [allow-red-base]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ci-config.sh"

POLL_INTERVAL_SECONDS=15
DEFAULT_MAX_WAIT_SECONDS=900

usage() {
  echo "Usage: $(basename "$0") <pr-number> [max-wait-seconds] [allow-red-base]" >&2
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

# base_branch_stop_reason <conclusion> [override]. Whether the BASE branch's own latest CI run
# should stop this merge. Prints nothing to mean "go ahead".
#
# #1006 fallout. check-pr-ci.sh answers "did THIS branch pass", and nothing asked "is main green
# BEFORE I land on it". On 2026-07-16 PR #1004 merged onto a main that had been red for 29
# minutes: the branch genuinely passed, every gate reported truthfully, and the merge still made
# things ambiguous, because once a second change lands on a red main nobody can tell which one
# broke it.
#
# A red base BLOCKS but is overridable. Not a hedge: without the override the gate deadlocks
# exactly when it matters, since the fix that makes main green could never be merged.
#
# An unknown base does NOT block. It is not evidence of breakage, and GitHub's Actions API
# answered 503 for this entire investigation. A gate that halts all work during someone else's
# outage is a worse failure than the one it prevents, and the PR's own checks are still the real
# gate. It says so out loud rather than passing silently.
base_branch_stop_reason() {
  local conclusion="$1" override="${2:-}"
  [[ "${override}" == "allow-red-base" ]] && return

  case "${conclusion}" in
    success) return ;;
    # Never "not failure, so fine": a cancelled or timed-out base has NOT been seen to be green,
    # and absence of failure is not a pass. That rule is why check-pr-ci.sh exists at all.
    failure|cancelled|timed_out|startup_failure|action_required) echo "base-red" ;;
    *) echo "base-unknown" ;;
  esac
}

# The base branch's latest completed run conclusion, or "" when it cannot be known (API outage,
# no runs yet, still going). Split from the decision above so the decision stays pure/testable.
base_branch_conclusion() {
  local branch="$1"
  gh_as_danwright32 run list -R "${REPO}" --branch "${branch}" --limit 1 \
    --json conclusion --jq '.[0].conclusion // ""' 2>/dev/null || echo ""
}

main() {
  [[ $# -ge 1 && $# -le 3 ]] || usage
  PR_NUMBER="$1"
  [[ "${PR_NUMBER}" =~ ^[0-9]+$ ]] || usage
  MAX_WAIT_SECONDS="${2:-${DEFAULT_MAX_WAIT_SECONDS}}"
  # #1006: explicit, positional, and never a default. The ONLY way past a red base.
  ALLOW_RED_BASE="${3:-}"

  START="$(date -u +%s)"

  while true; do
    if OUTPUT="$("${SCRIPT_DIR}/check-pr-ci.sh" "${PR_NUMBER}" 2>&1)"; then
      CODE=0
    else
      CODE=$?
    fi
    echo "${OUTPUT}"

    if [[ ${CODE} -eq 0 ]]; then
      # #1006: the PR passed. Now ask the question nothing asked before: is the branch we are
      # about to land ON actually green? Checked HERE, at the moment of merging, not at startup:
      # a poll loop can wait 15 minutes, and main's health at the start says nothing about its
      # health now.
      BASE_BRANCH="$(gh_as_danwright32 pr view "${PR_NUMBER}" -R "${REPO}" --json baseRefName --jq .baseRefName 2>/dev/null || echo "")"
      BASE_CONCLUSION="$(base_branch_conclusion "${BASE_BRANCH:-main}")"
      case "$(base_branch_stop_reason "${BASE_CONCLUSION}" "${ALLOW_RED_BASE}")" in
        base-red)
          echo
          echo "Stopped: ${BASE_BRANCH:-main} is currently RED (its last run: ${BASE_CONCLUSION}). Not merging." >&2
          echo "PR #${PR_NUMBER} passed on its own branch, but landing a second change on a broken base makes it impossible to tell which change broke it." >&2
          echo "Fix the base first. To merge anyway (for example, THIS PR is the fix), rerun with: $(basename "$0") ${PR_NUMBER} ${MAX_WAIT_SECONDS} allow-red-base" >&2
          exit 1
          ;;
        base-unknown)
          echo
          echo "Warning: could not determine whether ${BASE_BRANCH:-main} is green (its last run reported: '${BASE_CONCLUSION}'). Merging on the strength of this PR's own checks." >&2
          ;;
      esac

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
