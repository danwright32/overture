#!/usr/bin/env bash
set -euo pipefail

# Waits for a PR's CI to actually pass, via check-pr-ci.sh, then merges it. Never merges on
# the strength of "hasn't failed yet": only a genuine pass from check-pr-ci.sh triggers the
# merge. Stops, without merging, on a genuine failure, an unmergeable PR, or a timeout.
#
# #1006: also refuses to land on a RED base branch. A PR passing on its own branch says nothing
# about the branch it is about to join, and merging a second change onto a broken main makes it
# impossible to tell which change broke it. Overridable, because the fix for a red main has to be
# able to land.
#
# Usage: scripts/merge-when-green.sh <pr-number> [max-wait-seconds] [allow-red-base]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/ci-config.sh"
# The "does this branch touch the Mac project?" predicate, shared with the post-merge hook (#1251 Phase 3).
source "${SCRIPT_DIR}/lib/mac-project-paths.sh"
# The same completeness enumeration verify-and-merge-branch.sh enforces, from the one shared file,
# so a PR cannot be waved through by choosing the other merge script.
source "${SCRIPT_DIR}/lib/pr-completeness-guard.sh"
# merge_pr: the one implementation of the merge and everything that must follow one, shared with
# verify-and-merge-branch.sh so a fix to it cannot be missing from one of the two paths.
source "${SCRIPT_DIR}/lib/pr-merge.sh"
# delete_merged_local_branch, shared with verify-and-merge-branch.sh and tidy-checkout.sh (#2234).
source "${SCRIPT_DIR}/lib/checkout-tidy.sh"
# judge_ref_project_freshness: the one implementation of "is this ref's own committed project file
# fresh", shared with verify-and-merge-branch.sh and so with the batch path too (#2818).
source "${SCRIPT_DIR}/lib/project-freshness.sh"

POLL_INTERVAL_SECONDS=15
DEFAULT_MAX_WAIT_SECONDS=900
PBXPROJ_REL="${PROJECT_FRESHNESS_PATH_REL}"

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
  # #2199: a check that went red without a runner ever picking it up. Stopped IMMEDIATELY rather than
  # polled, which is the opposite of what it looks like it should do: GitHub will not re-run the job by
  # itself, so waiting the full window achieves nothing and only delays the one thing that helps. The
  # issue asked to re-run and keep waiting; re-running is a side effect this script should not take on
  # its own, and the thirty minutes lost on 2026-08-06 went to DIAGNOSIS rather than to waiting, which
  # naming the state fixes. check-pr-ci.sh prints the exact re-run command.
  #
  # Checked BEFORE the failure case below, because the never-started line is a red too and the coarser
  # rule would swallow it.
  if grep -q "Never started:" <<< "${output}"; then
    echo "never-started"
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

# Whether this branch touches the Mac project is decided by paths_touch_mac_project, sourced above from
# scripts/lib/mac-project-paths.sh and shared with the post-merge hook (#1251 Phase 3).

# Fetches the PR branch into a throwaway worktree and puts the SHARED freshness judgement over it,
# returning that gate's verdict (0 fresh, 1 refused having said which of the two refusals it is). A real
# side-effecting helper (git fetch + worktree + xcodegen), named and extracted so a fixture can stub it
# and drive the merge DECISION without touching git.
#
# Only the worktree is this script's own now (#2818). The judgement itself is
# judge_ref_project_freshness in scripts/lib/project-freshness.sh, the same one
# verify-and-merge-branch.sh's per-ref gate calls, so the two merge paths cannot answer this question
# differently. They already did: this script used to fold "stale" and "cannot be verified" into one
# sentence whose stated remedy was wrong for the second of them.
verify_branch_pbxproj_fresh() {
  local pr_number="$1"
  local branch worktree rc=0
  branch="$(gh_as_danwright32 pr view "${pr_number}" -R "${REPO}" --json headRefName --jq .headRefName)"
  worktree="$(mktemp -d "${TMPDIR:-/tmp}/overture-pbxproj-${branch//\//-}.XXXXXX")"
  git -C "${REPO_ROOT}" fetch -q origin "${branch}"
  git -C "${REPO_ROOT}" worktree add -q --detach "${worktree}" "origin/${branch}"
  judge_ref_project_freshness "${worktree}" "${branch}" || rc=$?
  git -C "${REPO_ROOT}" worktree remove --force "${worktree}" 2>/dev/null || true
  return "${rc}"
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

  # BEFORE the polling loop, deliberately. Placed after it, this waited out however long CI took and
  # only then refused, so the slowest possible feedback was attached to the cheapest possible fix.
  # verify-and-merge-branch.sh refuses before its worktree for the same reason.
  # #2822: the author and the changed files come with the body, because the ONE exemption (a known bot
  # bumping only dependency manifests) needs both halves. A `gh` call that fails yields an empty string
  # for either, and empty is never exempt.
  require_pr_completeness "${PR_NUMBER}" \
    "$(gh_as_danwright32 pr view "${PR_NUMBER}" -R "${REPO}" --json body --jq .body 2>/dev/null || echo "")" \
    "$(gh_as_danwright32 pr view "${PR_NUMBER}" -R "${REPO}" --json author --jq .author.login 2>/dev/null || echo "")" \
    "$(gh_as_danwright32 pr view "${PR_NUMBER}" -R "${REPO}" --json files --jq '.files[].path' 2>/dev/null || echo "")"

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

      # Decision 2 (#1368): remote CI no longer covers the Mac project since #1347, so a stale committed
      # project.pbxproj could ride in unseen. When (and only when) this branch touches the Mac app, verify
      # freshness in a throwaway worktree and BLOCK a stale one, the same gate verify-and-merge enforces. A
      # branch that touches nothing under mac/ cannot have changed the generated project, so it skips this.
      CHANGED_PATHS="$(gh_as_danwright32 pr view "${PR_NUMBER}" -R "${REPO}" --json files --jq '.files[].path' 2>/dev/null || echo "")"
      if [[ -n "$(paths_touch_mac_project "${CHANGED_PATHS}")" ]]; then
        echo
        echo "Branch touches the Mac app; verifying ${PBXPROJ_REL} is fresh before merging..."
        if ! verify_branch_pbxproj_fresh "${PR_NUMBER}"; then
          echo
          # The reason and its remedy are printed by judge_ref_project_freshness above, which is the only
          # thing that knows WHICH of the two refusals this is. Restating one of them here is how this
          # script came to tell someone to regenerate a file that was already correct (#2818, L11).
          echo "Stopped: ${PBXPROJ_REL} did not pass the freshness gate on this branch (the reason is above), so this merge is not going ahead." >&2
          exit 1
        fi
      fi

      echo
      echo "CI genuinely passed. Merging PR #${PR_NUMBER}..."
      MERGED_BRANCH="$(gh_as_danwright32 pr view "${PR_NUMBER}" -R "${REPO}" --json headRefName --jq .headRefName 2>/dev/null || echo "")"
      # The shared merge (scripts/lib/pr-merge.sh), not a second copy of the sequence: it merges, asks
      # GitHub whether the PR actually reached MERGED, and only then deletes the local branch and records
      # the shipped commit. This script used to carry its own copy of those four steps, and the copy in
      # verify-and-merge-branch.sh was the one that reported a failed merge as `merged` on 2026-08-13.
      if ! merge_pr "${PR_NUMBER}" "${MERGED_BRANCH}"; then
        echo
        echo "Stopped: CI passed but the merge itself did not go through, so PR #${PR_NUMBER} is still open." >&2
        echo "Its reason is above. Nothing was deleted and no shipped commit was recorded; rerun this once" >&2
        echo "the cause is dealt with." >&2
        exit 1
      fi
      exit 0
    fi

    case "$(classify_stop_reason "${OUTPUT}")" in
      conflict)
        echo
        echo "Stopped: PR #${PR_NUMBER} has a merge conflict, so CI checks will never appear. Not merging. Resolve the conflict, then rerun this script." >&2
        exit 1
        ;;
      never-started)
        echo
        echo "Stopped: a check went red without ever being picked up by a runner, so nothing ran and there is no failure to investigate. Not merging." >&2
        echo "This is GitHub's infrastructure, not this branch. Re-run the job (the command is printed above), then rerun this script." >&2
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
