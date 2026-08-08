#!/usr/bin/env bash
set -euo pipefail

# Verifies a branch's full local test suite in an isolated worktree, under the same shared
# xcodebuild lock as every other test run on this Mac, and merges its PR only if that run is
# clean (#525). Distinct from merge-when-green.sh, which trusts remote CI: this is for the "several
# agent-produced branches landed at once" case (see AGENTS.md's CI section), where the coordinating
# session re-verifies each branch's OWN worktree locally before merging, rather than trusting each
# agent's self report or waiting on a remote CI run per branch.
#
# Usage: scripts/verify-and-merge-branch.sh <pr-number-or-branch-name>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/ci-config.sh"
# Reuses check_mergeable (and its ${PR_NUMBER}-keyed message) rather than duplicating the
# CONFLICTING guard; sourcing never runs check-pr-ci.sh's own main().
source "${SCRIPT_DIR}/check-pr-ci.sh"
# delete_merged_local_branch, shared with merge-when-green.sh and tidy-checkout.sh (#2234).
source "${SCRIPT_DIR}/lib/checkout-tidy.sh"

usage() {
  echo "Usage: $(basename "$0") <pr-number-or-branch-name>" >&2
  exit 1
}

# Resolves the gh identifier (a PR number or a branch name both work with `gh pr view`) into the
# globals verify_and_merge and check_mergeable need: PR_NUMBER, PR_BRANCH, PR_MERGEABLE. Named and
# extracted, rather than inlined, so a test can stub it instead of calling gh for real.
resolve_pr() {
  local identifier="$1"
  local info
  info="$(gh_as_danwright32 pr view "${identifier}" -R "${REPO}" --json number,headRefName,mergeable --jq '[.number, .headRefName, .mergeable] | @tsv')"
  IFS=$'\t' read -r PR_NUMBER PR_BRANCH PR_MERGEABLE <<< "${info}"
}

# Fetches the branch and adds a detached, throwaway worktree for it, setting WORKTREE_DIR. Named
# and extracted so a test can stub it instead of touching real git state.
setup_worktree() {
  local branch="$1"
  WORKTREE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/overture-verify-${branch//\//-}.XXXXXX")"
  git -C "${REPO_ROOT}" fetch origin "${branch}"
  git -C "${REPO_ROOT}" worktree add --detach "${WORKTREE_DIR}" "origin/${branch}"
}

# Runs the full local suite in the given worktree. #1368: it used to run `xcodegen generate` FIRST, which
# silently rewrote a STALE committed .pbxproj in this throwaway worktree so the staleness passed here and
# then landed on main anyway. Instead, check freshness BEFORE anything regenerates the project:
# check-pbxproj-fresh.sh does its own regen-and-restore and BLOCKS on a stale committed file (comparing a
# file to a fresh regen, not to itself). It runs again inside test-all.sh, so this is the belt for the
# merge path's suspenders. Named and extracted so a test can stub it to simulate a clean or failing run
# without spending minutes on a real xcodebuild invocation.
run_full_suite() {
  local dir="$1"
  "${dir}/scripts/check-pbxproj-fresh.sh" "${dir}"
  "${dir}/scripts/test-all.sh"
}

# Removes the throwaway worktree. Named and extracted so a test can assert it runs on BOTH the
# happy and failure paths: a failed verification must not leave the worktree behind either.
cleanup_worktree() {
  local dir="$1"
  git -C "${REPO_ROOT}" worktree remove --force "${dir}" 2>/dev/null || true
}

# Merges the PR. Named and extracted so a test can assert it was (or wasn't) called, instead of
# ever calling gh pr merge for real during a test run.
merge_pr() {
  local pr_number="$1" merged_branch="${2:-}"
  gh_as_danwright32 pr merge "${pr_number}" -R "${REPO}" --squash --delete-branch
  # #2234: --delete-branch only removes the branch on GitHub. Without this the local ref survives
  # every merge, which is how the checkout reached 496 branches. Never fatal, same reason as below.
  delete_merged_local_branch "${merged_branch}" || true
  # #1808: something shipped, so record it for the app to compare its own build against, and say the
  # same thing in the terminal (which is what finally gives #1345's freshness check a caller). Neither
  # is fatal: the merge has already happened, and failing here would report it as a failure.
  "${REPO_ROOT}/scripts/record-shipped-commit.sh" || true
  "${REPO_ROOT}/mac/scripts/check-release-freshness.sh" || true
}

# The orchestration: resolve the PR, bail on a merge conflict or an unresolvable identifier,
# verify the branch's own worktree, and merge only if that run was clean, always cleaning up the
# worktree either way. Pure control flow over the named functions above, so a test can stub every
# side-effecting step and assert the DECISION (merge or hold) on both the happy and failure paths
# without ever touching real git, gh, or xcodebuild.
verify_and_merge() {
  local identifier="$1"
  PR_NUMBER=""
  PR_BRANCH=""
  PR_MERGEABLE=""
  WORKTREE_DIR=""
  resolve_pr "${identifier}"

  if [[ -z "${PR_NUMBER}" || "${PR_NUMBER}" == "null" ]]; then
    echo "Error: could not resolve a PR for '${identifier}' on ${REPO}." >&2
    return 1
  fi

  check_mergeable "${PR_MERGEABLE}" || return 1

  echo "Verifying PR #${PR_NUMBER} (${PR_BRANCH}) in an isolated worktree..."
  setup_worktree "${PR_BRANCH}"

  local suite_exit_code=0
  run_full_suite "${WORKTREE_DIR}" || suite_exit_code=$?

  cleanup_worktree "${WORKTREE_DIR}"

  if [[ "${suite_exit_code}" -ne 0 ]]; then
    echo "Local suite failed for PR #${PR_NUMBER} (${PR_BRANCH}); not merging." >&2
    return 1
  fi

  echo "Local suite clean for PR #${PR_NUMBER} (${PR_BRANCH}). Merging..."
  merge_pr "${PR_NUMBER}" "${PR_BRANCH}"
}

main() {
  [[ $# -eq 1 ]] || usage
  command -v gh >/dev/null || { echo "gh CLI not found; install it and run: gh auth login" >&2; exit 1; }
  verify_and_merge "$1"
}

# Allow this file to be sourced (e.g. by a test fixture) without running main, so
# verify_and_merge can be exercised directly. Mirrors merge-when-green.sh's convention.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
