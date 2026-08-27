#!/usr/bin/env bash
set -euo pipefail

# Verifies SEVERAL PRs together in one local suite run and merges them all only if that combined run is
# clean (#2602).
#
# WHY. verify-and-merge-branch.sh verifies one PR at a time, so a three PR evening pays the whole Swift
# suite three times, serialized under the shared xcodebuild lock. The combined run is not just cheaper,
# it is also the run that answers the question that matters: two changes that are each green can merge
# into a broken main, because each was verified against a base that did not contain the other (L85, and
# measured here on 2026-08-09, when PR #2345 was green on its own branch and red on the main that
# already carried #1575 and #1940). Combining several branches with current main and running the suite
# once tests exactly the tree that will exist after all of them land.
#
# WHAT IT COSTS. A combined run cannot attribute a failure to one branch. That is stated plainly on the
# red path rather than guessed at: the message names every branch in the combination and says the red
# belongs to the combination, so the next step is a decision (drop one and rerun, or fix the
# interaction) rather than a mistaken belief about which branch is at fault.
#
# Everything expensive or destructive is reused from verify-and-merge-branch.sh rather than copied, so
# the two merge paths cannot disagree about what a mergeable PR looks like, where the verify worktree
# lives, or what the suite is.
#
# Usage: scripts/verify-and-merge-batch.sh <pr-number-or-branch> <pr-number-or-branch> [...]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Sourcing brings resolve_pr, setup_worktree, run_full_suite, merge_pr, release_verify_slot,
# check_mergeable and require_pr_completeness, and runs nothing: that script's main() is guarded by the
# same BASH_SOURCE convention this one uses.
# shellcheck source=./verify-and-merge-branch.sh
source "${SCRIPT_DIR}/verify-and-merge-branch.sh"

usage() {
  echo "Usage: $(basename "$0") <pr-number-or-branch> <pr-number-or-branch> [...]" >&2
  echo "" >&2
  echo "Verifies every named PR together in ONE local suite run and merges them all only if it is" >&2
  echo "clean. For a single PR use verify-and-merge-branch.sh." >&2
  exit 1
}

# merge_branch_into_worktree <dir> <branch>: fetches the branch and merges it into the worktree.
# Returns nonzero, leaving no half-merged tree behind, when it conflicts.
#
# Named and extracted so a test can stub it and assert the DECISION without a real fetch or merge.
merge_branch_into_worktree() {
  local dir="$1" branch="$2"
  git -C "${REPO_ROOT}" fetch origin "${branch}" || return 1
  # An identity, because a detached worktree still needs one to record a merge commit, and a Mac
  # without a global user.email would otherwise fail here for a reason unrelated to the branch.
  if ! git -C "${dir}" -c user.name="Overture verify" -c user.email="verify@localhost" \
        merge --no-edit "origin/${branch}"; then
    git -C "${dir}" merge --abort 2>/dev/null || true
    return 1
  fi
}

# combine_branches <dir> <branch>...: merges every branch into the worktree, which is already at
# current origin/main, and REFUSES at the first conflict rather than resolving anything.
#
# A conflict here is a real question about two people's intent, and the caller must not run the suite
# over a conflicted or half-merged tree: such a run judges a state that will never exist, and it can
# come back green just as easily as red, which is the reading that would send the broken combination to
# main. So the refusal names the branch that would not go in and says nothing was verified.
#
# What is NOT a conflict, and used to be refused as one (#2812): the post-merge hook regenerating the
# project file after each merge and leaving it STAGED. The next merge then dies on "Your local changes
# would be overwritten", which carries no decision at all, so commit_merge_regeneration settles it
# between combines. See its comment for why that is not the blind regeneration of #1368.
combine_branches() {
  local dir="$1"
  shift
  local branch
  for branch in "$@"; do
    echo "Combining ${branch}..."
    if ! merge_branch_into_worktree "${dir}" "${branch}"; then
      echo "Cannot combine ${branch} with what is already in the verify worktree: the merge conflicts." >&2
      echo "Nothing was verified and nothing was merged, because a suite run over a conflicted tree judges" >&2
      echo "a state that will never exist." >&2
      echo "Resolve it on ${branch} (regenerate mac/Overture.xcodeproj/project.pbxproj if that is the" >&2
      echo "conflict), push, then rerun. Or rerun this without ${branch} to land the rest." >&2
      return 1
    fi
    if ! commit_merge_regeneration "${dir}"; then
      echo "Nothing was verified and nothing was merged: the verify worktree was left in a state after" >&2
      echo "merging ${branch} that this script will not commit on top of." >&2
      return 1
    fi
  done
}

# merge_all <pr-number>|<branch> pairs, as two index-aligned arrays: merges every PR, CONTINUING past
# one that fails, and returns nonzero if any did.
#
# Continuing is deliberate. GitHub squash-merges these one at a time, so the second merge can be
# refused for a reason the combined local run could not see (a squash that conflicts with the first one
# once it has landed). Stopping at the first failure would leave the rest unattempted and unreported,
# which is indistinguishable from never having been asked (L47); the summary says exactly which landed
# and which did not.
merge_all() {
  local -a numbers=() branches=()
  local pair
  for pair in "$@"; do
    numbers+=("${pair%%:*}")
    branches+=("${pair#*:}")
  done

  local i failed=0
  for i in "${!numbers[@]}"; do
    echo "Merging PR #${numbers[$i]} (${branches[$i]})..."
    if merge_pr "${numbers[$i]}" "${branches[$i]}"; then
      MERGE_RESULTS+=("merged   PR #${numbers[$i]} (${branches[$i]})")
    else
      MERGE_RESULTS+=("REFUSED  PR #${numbers[$i]} (${branches[$i]}) was verified but GitHub would not merge it")
      failed=$((failed + 1))
    fi
  done

  echo
  printf '  %s\n' "${MERGE_RESULTS[@]}"
  [[ "${failed}" -eq 0 ]]
}

# The orchestration. Pure control flow over the named functions above, so a test can stub every
# side-effecting step and assert the DECISION on each path without touching real git, gh or xcodebuild.
verify_and_merge_batch() {
  local -a identifiers=("$@")
  local -a numbers=() branches=() pairs=()
  MERGE_RESULTS=()

  # Resolve and refuse EVERYTHING up front, deliberately: a batch that is going to be refused should
  # cost seconds, not a two minute wait for the exclusive test lock followed by a refusal.
  local identifier
  for identifier in "${identifiers[@]}"; do
    PR_NUMBER=""
    PR_BRANCH=""
    PR_MERGEABLE=""
    PR_BODY=""
    resolve_pr "${identifier}"

    if [[ -z "${PR_NUMBER}" || "${PR_NUMBER}" == "null" ]]; then
      echo "Error: could not resolve a PR for '${identifier}' on ${REPO}." >&2
      echo "Nothing was verified and nothing was merged." >&2
      return 1
    fi

    # A repeated PR would be merged into the worktree twice and then merged on GitHub twice. Refused
    # rather than quietly deduplicated, because naming the same PR twice means somebody's list is
    # wrong, and silently doing something different from what was asked is how that stays hidden.
    local seen
    for seen in ${numbers[@]+"${numbers[@]}"}; do
      if [[ "${seen}" == "${PR_NUMBER}" ]]; then
        echo "Error: PR #${PR_NUMBER} was named twice in this batch." >&2
        echo "Nothing was verified and nothing was merged." >&2
        return 1
      fi
    done

    check_mergeable "${PR_MERGEABLE}" || {
      echo "Nothing was verified and nothing was merged." >&2
      return 1
    }
    require_pr_completeness "${PR_NUMBER}" "${PR_BODY}" "${PR_AUTHOR:-}" "${PR_FILES:-}"
    # #3159, in the same up-front pass as everything else that can refuse a PR before the one
    # expensive suite run starts, so a batch never pays for a combine it is going to reject.
    PR_BODY_CLAIMS_GH=gh_as_danwright32 check_pr_body_claims "${PR_NUMBER}" "${PR_BODY}" || {
      echo "Nothing was verified and nothing was merged." >&2
      return 1
    }

    numbers+=("${PR_NUMBER}")
    branches+=("${PR_BRANCH}")
    pairs+=("${PR_NUMBER}:${PR_BRANCH}")
  done

  echo "Verifying ${#numbers[@]} PRs together in one suite run:"
  local i
  for i in "${!numbers[@]}"; do
    echo "  #${numbers[$i]} (${branches[$i]})"
  done

  # The base is current origin/main, so the combined tree IS what will exist after all of them land
  # (#2353, L85). Nothing else needs to bring main in.
  # Checked for the same reason as on the single-PR path: this function is called where errexit is
  # suspended, so a refused slot has to stop the run explicitly rather than fall through into a suite
  # run over whatever the worktree happens to hold (#2923).
  if ! setup_worktree "main"; then
    release_verify_slot
    echo "Nothing was verified and nothing was merged." >&2
    return 1
  fi

  # BEFORE any merge and before the post-merge hook regenerates anything (#2812). Each ref's own project
  # file is judged exactly as its author committed it, which is the version that reaches main, so the
  # regeneration committed between combines below can only ever be about the combination.
  if ! gate_branch_project_freshness "${WORKTREE_DIR}" "main" "${branches[@]}"; then
    release_verify_slot
    echo "Nothing was verified and nothing was merged." >&2
    return 1
  fi

  if ! combine_branches "${WORKTREE_DIR}" "${branches[@]}"; then
    release_verify_slot
    return 1
  fi

  # #2946: the copy documents are settled ONCE, on the whole combination, which is where a batch pays for
  # this least. Two branches that each add a Dan-facing sentence conflict on those files by construction
  # and neither side's text is anybody's to write.
  if ! rebuild_copy_docs "${WORKTREE_DIR}"; then
    release_verify_slot
    return 1
  fi

  local suite_exit_code=0
  run_full_suite "${WORKTREE_DIR}" || suite_exit_code=$?

  release_verify_slot

  if [[ "${suite_exit_code}" -ne 0 ]]; then
    echo >&2
    echo "The combined suite failed. This red belongs to the COMBINATION, not to any one of these:" >&2
    for i in "${!numbers[@]}"; do
      echo "  #${numbers[$i]} (${branches[$i]})" >&2
    done
    echo "A combined run cannot attribute a failure to one branch, so do not read it as the last one" >&2
    echo "named. Nothing was merged. Rerun with a smaller set to find which pair interacts, or fix the" >&2
    echo "interaction on whichever branch owns it." >&2
    return 1
  fi

  echo
  echo "Combined suite clean for all ${#numbers[@]} PRs. Merging..."
  merge_all "${pairs[@]}"
}

main() {
  [[ $# -ge 1 ]] || usage
  command -v gh >/dev/null || { echo "gh CLI not found; install it and run: gh auth login" >&2; exit 1; }
  verify_and_merge_batch "$@"
}

# Allow this file to be sourced (e.g. by a test fixture) without running main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
