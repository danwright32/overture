#!/usr/bin/env bash
set -euo pipefail

# Verifies a branch's full local test suite in an isolated worktree, under the same shared
# xcodebuild lock as every other test run on this Mac, and merges its PR only if that run is
# clean (#525). Distinct from merge-when-green.sh, which trusts remote CI: this is for the "several
# agent-produced branches landed at once" case (see AGENTS.md's CI section), where the coordinating
# session re-verifies each branch's OWN worktree locally before merging, rather than trusting each
# agent's self report or waiting on a remote CI run per branch.
#
# The worktree is one PERSISTENT slot at a fixed path (default ~/.overture-verify-worktree,
# override with OVERTURE_VERIFY_WORKTREE), scrubbed back to a fresh checkout at the start of every
# verification and locked while in use (#2601). See setup_worktree for why the path being fixed is
# the whole speedup.
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
# merge_pr, the one implementation of the merge and everything that must follow one, shared with
# merge-when-green.sh for the same reason (#2602 found the two copies needing the same fix).
source "${SCRIPT_DIR}/lib/pr-merge.sh"

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

# Fetches the branch and points the PERSISTENT verify worktree at its tip, setting WORKTREE_DIR.
# Named and extracted so a test can stub it instead of touching real git state.
#
# ONE fixed path, reused by every verification, deliberately (#2601). Xcode keys DerivedData by
# workspace path, so the old throwaway path per verification paid a full cold build every time
# (75s measured against a warm run, 2026-08-12) and minted a ~1.6 GB build folder that needed its
# own cleanup (#2585). A fixed path keeps that build incremental and mints exactly one folder,
# which reclaim-orphan-derived-data.sh keeps for as long as the slot exists.
#
# Reuse must equal a fresh checkout, so whatever the previous verification (or its crash) left in
# the slot is scrubbed before WORKTREE_DIR is handed back: any in-progress merge aborted, the tree
# forced to exactly the fetched tip, everything untracked or ignored removed (node_modules costs
# under a second to come back; the build cache lives outside the checkout and is untouched). A slot
# that cannot be scrubbed, or that belongs to some other repo, is rebuilt from nothing rather than
# trusted, since the whole point of the scrub is that the suite judges only the branch.
setup_worktree() {
  local branch="$1"
  WORKTREE_DIR="${OVERTURE_VERIFY_WORKTREE:-${HOME}/.overture-verify-worktree}"
  local slot_lock="${OVERTURE_VERIFY_WORKTREE_LOCK:-/tmp/overture-verify-worktree.lock}"

  # Two verifications must not share the slot: the second would scrub the first mid-suite. The lock
  # is a kernel flock, so a crashed holder releases it by dying, and the wait announces itself
  # because a silent wait is indistinguishable from a hang for as long as the other suite takes
  # (L110). Held on fd 9 until release_verify_slot closes it.
  exec 9>"${slot_lock}"
  if ! flock -n 9; then
    echo "Another verification holds the verify worktree; waiting for it to finish (lock: ${slot_lock})..." >&2
    flock 9
    echo "Got the verify worktree." >&2
  fi

  git -C "${REPO_ROOT}" fetch origin "${branch}"

  # Reuse the slot only when it is a live worktree of THIS repo. Comparing the two sides through
  # independent lookups (the slot's own answer against the checkout's), because scrubbing a
  # directory that merely looks like a worktree would run `git clean -ffdx` inside whatever repo it
  # actually belongs to (L70).
  local expected_common actual_common
  expected_common="$(git -C "${REPO_ROOT}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  actual_common="$(git -C "${WORKTREE_DIR}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -n "${expected_common}" && "${actual_common}" == "${expected_common}" ]]; then
    git -C "${WORKTREE_DIR}" merge --abort >/dev/null 2>&1 || true
    if git -C "${WORKTREE_DIR}" checkout --force --detach "origin/${branch}" >/dev/null 2>&1 \
      && git -C "${WORKTREE_DIR}" clean -ffdx >/dev/null 2>&1; then
      return 0
    fi
    echo "The verify worktree at ${WORKTREE_DIR} could not be scrubbed; rebuilding it from nothing." >&2
  fi

  git -C "${REPO_ROOT}" worktree remove --force "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  git -C "${REPO_ROOT}" worktree prune >/dev/null 2>&1 || true
  rm -rf "${WORKTREE_DIR}"
  git -C "${REPO_ROOT}" worktree add --detach "${WORKTREE_DIR}" "origin/${branch}"
}

# Brings current origin/main into the verify worktree, so what the suite judges is what will
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
# silently rewrote a STALE committed .pbxproj in the verify worktree so the staleness passed here and
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

# Releases the verify slot's lock, and nothing else: the worktree, its registration, and its Xcode
# build folder all stay, because the warm build cache is the point (#2601) and the next
# verification's setup scrubs the checkout anyway. Named and extracted so a test can assert it runs
# on BOTH the happy and failure paths: a failed verification must not leave the slot locked either.
#
# Closing the fd explicitly, rather than leaving it to process exit, because verify_and_merge can be
# called more than once from one shell (a test fixture does; a batch session could).
#
# The #2585 leak this script used to clean up after itself is gone at the source: one fixed path
# mints one build folder, kept warm on purpose, and reclaim-orphan-derived-data.sh keeps any folder
# whose workspace still exists.
release_verify_slot() {
  exec 9>&- 2>/dev/null || true
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

  echo "Verifying PR #${PR_NUMBER} (${PR_BRANCH}) in the verify worktree..."
  setup_worktree "${PR_BRANCH}"

  # #2353: combine BEFORE the suite, and stop here if it cannot be done. The slot still gets
  # released, because a slot left locked blocks every verification after it.
  if ! combine_with_main "${WORKTREE_DIR}"; then
    release_verify_slot
    echo "Not merging PR #${PR_NUMBER} (${PR_BRANCH})." >&2
    return 1
  fi

  local suite_exit_code=0
  run_full_suite "${WORKTREE_DIR}" || suite_exit_code=$?

  release_verify_slot

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
