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
# The completeness enumeration AGENTS.md demands. Shared with merge-when-green.sh so the two merge
# paths cannot disagree about what a mergeable PR looks like.
source "${SCRIPT_DIR}/lib/pr-completeness-guard.sh"
# derived_data_reclaim_for_workspace, so the build output this script's throwaway worktree causes goes
# when the worktree does (#2585).
source "${SCRIPT_DIR}/lib/derived-data.sh"

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
  # Fetched separately because a body is multi-line and would break the tab-separated read above.
  PR_BODY="$(gh_as_danwright32 pr view "${identifier}" -R "${REPO}" --json body --jq .body 2>/dev/null || echo "")"
}

# Fetches the branch and adds a detached, throwaway worktree for it, setting WORKTREE_DIR. Named
# and extracted so a test can stub it instead of touching real git state.
setup_worktree() {
  local branch="$1"
  WORKTREE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/overture-verify-${branch//\//-}.XXXXXX")"
  git -C "${REPO_ROOT}" fetch origin "${branch}"
  git -C "${REPO_ROOT}" worktree add --detach "${WORKTREE_DIR}" "origin/${branch}"
}

# Brings current origin/main into the throwaway worktree, so what the suite judges is what will
# EXIST after merging rather than what the branch was cut from (#2353, L85).
#
# Two changes that are each green can merge into a broken main, because each was verified against a
# base that did not contain the other, and this script's whole reason for existing is the case where
# several branches land at once. Measured 2026-08-09: PR #2345 was green on its own branch and red
# once merged onto the main that already carried #1575 and #1940, caught only because that merge was
# combined by hand.
#
# It REFUSES rather than resolving anything. A conflict here is a real question about two people's
# intent, and the repo has no merge driver for its generated files, so the honest answer is to stop
# and name what could not be combined. The caller must not run the suite over a conflicted tree: a
# half-merged tree can come back green just as easily as red, and green is the reading that would
# send the broken combination to main.
#
# Named and extracted so a test can stub it and assert the DECISION without a real fetch or merge.
combine_with_main() {
  local dir="$1"
  git -C "${REPO_ROOT}" fetch origin main || return 1
  # An identity, because a detached worktree still needs one to record a merge commit, and a Mac
  # without a global user.email would otherwise fail here for a reason unrelated to the branch.
  if ! git -C "${dir}" -c user.name="Overture verify" -c user.email="verify@localhost" \
        merge --no-edit origin/main; then
    git -C "${dir}" merge --abort 2>/dev/null || true
    echo "Cannot combine ${PR_BRANCH} with current main: the merge conflicts." >&2
    echo "Nothing was verified, because a suite run over a conflicted tree judges a state that will never exist." >&2
    echo "Resolve it on the branch (regenerate mac/Overture.xcodeproj/project.pbxproj if that is the conflict), push, then rerun." >&2
    return 1
  fi
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

# Drops git's registration of the throwaway worktree and the directory with it. Split out from
# cleanup_worktree so a test can exercise the derived-data half below without touching real git.
remove_worktree_registration() {
  local dir="$1"
  git -C "${REPO_ROOT}" worktree remove --force "${dir}" 2>/dev/null || true
}

# Removes the throwaway worktree AND the Xcode build folder that building it created (#2585).
#
# Named and extracted so a test can assert it runs on BOTH the happy and failure paths: a failed
# verification must not leave the worktree behind either.
#
# The build folder is the part that used to be left behind. Xcode keys DerivedData by the workspace
# PATH, so each verification's brand new worktree mints a fresh folder of roughly 1.6 GB, outside the
# checkout, that nothing here ever went back for. Five verifications in one session on 2026-08-12 left
# five of them, and the pile eventually filled the disk (#2585). This script created both paths and
# knows both, so it is the cheapest place to close it: scripts/reclaim-orphan-derived-data.sh sweeping
# later is the net under it, not the fix.
#
# Scoped strictly to this worktree's own folder. Other verifications and other agents run concurrently
# under the same shared xcodebuild lock, and taking one of their live folders would cost that run a
# full cold rebuild.
cleanup_worktree() {
  local dir="$1"
  remove_worktree_registration "${dir}"
  derived_data_reclaim_for_workspace "$(derived_data_root)" "${dir}" >/dev/null || true
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
  # Bound here with the rest, never left to resolve_pr: this script runs under `set -u`, so an unset
  # PR_BODY kills it on the guard line below with no output at all, which is the same traceless death
  # #1711 fixed in the runners. A test that stubs resolve_pr is exactly how that would first appear.
  PR_BODY=""
  WORKTREE_DIR=""
  resolve_pr "${identifier}"

  if [[ -z "${PR_NUMBER}" || "${PR_NUMBER}" == "null" ]]; then
    echo "Error: could not resolve a PR for '${identifier}' on ${REPO}." >&2
    return 1
  fi

  check_mergeable "${PR_MERGEABLE}" || return 1
  # BEFORE the suite, deliberately: a body missing the enumeration is refused in seconds rather
  # than after two minutes of exclusive test lock, and the fix does not need a re-run of anything.
  require_pr_completeness "${PR_NUMBER}" "${PR_BODY}"

  echo "Verifying PR #${PR_NUMBER} (${PR_BRANCH}) in an isolated worktree..."
  setup_worktree "${PR_BRANCH}"

  # #2353: combine BEFORE the suite, and stop here if it cannot be done. The worktree still gets
  # cleaned up, because a throwaway tree left behind is litter either way.
  if ! combine_with_main "${WORKTREE_DIR}"; then
    cleanup_worktree "${WORKTREE_DIR}"
    echo "Not merging PR #${PR_NUMBER} (${PR_BRANCH})." >&2
    return 1
  fi

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
