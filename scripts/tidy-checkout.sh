#!/usr/bin/env bash
set -uo pipefail

# Removes local branches and agent worktrees whose work has provably shipped (#2234, #2228, #2099).
#
# Measured 2026-08-06: 496 local branches (git recognised 39 as merged), 10 agent worktrees at
# 652 MB, 5 worktree registrations pointing at directories that no longer exist. Nothing was
# broken, but a repo-wide search returned each hit ten times over and it was slow to see what was
# actually live.
#
# The accumulation is continuous, not a one-off, which is why this is a script and not a session of
# hand-deleting. Two leaks feed it:
#   * `gh pr merge --delete-branch` removes the REMOTE branch and leaves the local ref forever.
#     scripts/merge-when-green.sh and scripts/verify-and-merge-branch.sh now delete it themselves,
#     so from here on this script is cleaning up the backlog rather than the daily flow.
#   * An agent worktree is auto-removed only when it made NO changes, so every worktree that did
#     real work is deposited permanently.
#
# Safety. Nothing here may delete work that never shipped, and 456 of those 496 branches are
# indistinguishable from shipped ones by the obvious test (see scripts/lib/checkout-tidy.sh for why
# `git branch --merged` cannot answer this in a squash-merging repo). So:
#   * A DRY RUN is the default. Deleting requires --apply, typed deliberately.
#   * Every branch must be proved contained in main, by patch or by a merged PR, before it goes.
#   * main, the current branch, anything with an open PR, anything checked out in a worktree, and
#     any worktree holding uncommitted work are all kept regardless.
#   * Every question that cannot be answered is answered in the keep direction.
#
# Usage:
#   scripts/tidy-checkout.sh              # dry run: report what would be removed, change nothing
#   scripts/tidy-checkout.sh --apply      # actually remove it
#   scripts/tidy-checkout.sh --apply --clean-build   # also delete mac/build (1.9 GB of rebuildable
#                                                    # derived data; the next build is a slow one)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# #2301: overridable so a fixture can run the REAL driver against a throwaway repository. The
# decision (scripts/lib/checkout-tidy.sh) has 31 fixtures; nothing covered the part that turns a
# verdict into `git branch -D`, which is the piece that was wrong twice while being written. Defaulted
# to the script's own checkout, so every ordinary invocation is unchanged.
REPO_ROOT="${TIDY_CHECKOUT_REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

# shellcheck source=./lib/checkout-tidy.sh
source "${SCRIPT_DIR}/lib/checkout-tidy.sh"
# shellcheck source=./ci-config.sh
source "${SCRIPT_DIR}/ci-config.sh"

APPLY="no"
CLEAN_BUILD="no"

usage() {
  echo "Usage: scripts/tidy-checkout.sh [--apply] [--clean-build]" >&2
  exit 2
}

# One line per registered worktree, "path<TAB>branch", with the branch left empty for a detached
# HEAD. Parsed from --porcelain rather than the human listing, whose columns shift with path length.
worktree_rows() {
  git -C "${REPO_ROOT}" worktree list --porcelain | awk '
    /^worktree /  { path = substr($0, 10) }
    /^branch /    { br = substr($0, 8); sub(/^refs\/heads\//, "", br); print path "\t" br; path=""; br="" }
    /^detached$/  { print path "\t"; path="" }
  '
}

# Every branch any worktree currently has checked out, including this one. A branch on this list is
# never deleted: git refuses anyway, and more to the point that worktree is somebody's live work.
worktree_branches() {
  worktree_rows | cut -f2 | grep -v '^$' || true
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply)       APPLY="yes"; shift ;;
      --clean-build) CLEAN_BUILD="yes"; shift ;;
      -h|--help)     usage ;;
      *)             echo "Unknown argument: $1" >&2; usage ;;
    esac
  done

  cd "${REPO_ROOT}"

  if [[ "${APPLY}" == "yes" ]]; then
    echo "Mode: APPLY (this will delete things)"
  else
    echo "Mode: dry run (nothing will be deleted; rerun with --apply to act)"
  fi
  echo

  local current_branch wt_branches
  current_branch="$(git rev-parse --abbrev-ref HEAD)"
  wt_branches="$(worktree_branches)"

  # One call for every merged head branch and one for every open one, rather than two calls per
  # branch. At 496 branches the per-branch form would be a thousand API calls, which is slow enough
  # that nobody would run this twice.
  #
  # An empty result here is ambiguous by construction: it is what both "no PRs" and "gh could not
  # answer" look like. So the two cases are told apart by the exit status and recorded separately,
  # and when gh failed, every branch is handed an EMPTY count, which classify_branch reads as "no
  # evidence" rather than "no PR". That leaves cherry as the only proof, which can only keep more.
  local merged_heads="" open_heads="" gh_ok="yes"
  echo "Reading PR history from GitHub..."
  if ! merged_heads="$(gh_as_danwright32 pr list -R "${REPO}" --state merged --limit 2000 --json headRefName --jq '.[].headRefName' 2>/dev/null)"; then
    gh_ok="no"
  fi
  if [[ "${gh_ok}" == "yes" ]] && ! open_heads="$(gh_as_danwright32 pr list -R "${REPO}" --state open --limit 500 --json headRefName --jq '.[].headRefName' 2>/dev/null)"; then
    gh_ok="no"
  fi

  if [[ "${gh_ok}" == "no" ]]; then
    echo "Could not read PR history (gh unavailable, unauthenticated, or offline)."
    echo "Continuing on patch containment alone, which recognises fewer branches as shipped."
    echo "Nothing is deleted on a guess: a branch that cannot be proved contained is kept."
    merged_heads=""
    open_heads=""
  else
    echo "Read $(count_lines "${merged_heads}") merged and $(count_lines "${open_heads}") open PR head branches."
  fi
  echo

  tidy_worktrees "${current_branch}" "${merged_heads}" "${open_heads}" "${gh_ok}"
  tidy_branches "${current_branch}" "${merged_heads}" "${open_heads}" "${gh_ok}"
  report_build_dir
  report_derived_data
}

# Deliberately NOT `[[ -z "${1//[[:space:]]/}" ]]` first. Bash pattern substitution with a character
# class is quadratic in the string's length, and the string here is every merged PR head branch in
# the repo (997 of them, about 40 KB), which took the emptiness check alone past four minutes of
# solid CPU with nothing printed. grep answers the same question in one pass, and prints 0 for an
# empty input on its own.
count_lines() {
  printf '%s' "$1" | grep -c . || true
}

# The evidence for one branch, as classify_branch wants it. When gh could not answer, the counts are
# deliberately EMPTY strings rather than 0, because 0 asserts something this run did not measure.
#
# The cheap pass runs FIRST and `git cherry` is only paid for when it comes back needs-cherry.
# Passing cherry in as an argument unconditionally was the first version of this, and it took the
# run past ten minutes without finishing: the shell evaluates an argument before the call, so a
# check inside the callee cannot make the call cheap (L62). Most branches here have a merged PR,
# which settles them for free.
branch_verdict() {
  local branch="$1" current_branch="$2" merged_heads="$3" open_heads="$4" gh_ok="$5" wt_branches="$6"
  local merged_count="" open_count="" cherry_output=""

  if [[ "${gh_ok}" == "yes" ]]; then
    merged_count="$(printf '%s\n' "${merged_heads}" | grep -cxF "${branch}")" || merged_count=0
    open_count="$(printf '%s\n' "${open_heads}" | grep -cxF "${branch}")" || open_count=0
  fi

  local early
  early="$(classify_branch_before_cherry "${branch}" "${current_branch}" \
    "${merged_count}" "${open_count}" "${wt_branches}")"
  if [[ "${early}" != "needs-cherry" ]]; then
    echo "${early}"
    return 0
  fi

  cherry_output="$(git cherry main "${branch}" 2>&1)" || cherry_output="git cherry failed"

  classify_branch "${branch}" "${current_branch}" "${cherry_output}" \
    "${merged_count}" "${open_count}" "${wt_branches}"
}

tidy_worktrees() {
  local current_branch="$1" merged_heads="$2" open_heads="$3" gh_ok="$4"
  local main_worktree removed=0 kept=0 prunable=0
  main_worktree="$(git rev-parse --path-format=absolute --show-toplevel)"

  echo "== Worktrees =="

  local path branch is_main path_exists dirty contained verdict
  while IFS=$'\t' read -r path branch; do
    [[ -z "${path}" ]] && continue
    is_main="no"; [[ "${path}" == "${main_worktree}" ]] && is_main="yes"
    path_exists="no"; [[ -d "${path}" ]] && path_exists="yes"

    dirty="no"
    if [[ "${path_exists}" == "yes" && "${is_main}" == "no" ]]; then
      [[ -n "$(git -C "${path}" status --porcelain 2>/dev/null)" ]] && dirty="yes"
    fi

    # Asked WITHOUT the worktree list, because "checked out by a worktree" is true of every branch
    # here by definition and would make every one of them unshippable. What matters for a worktree
    # is only whether its branch's work landed.
    contained="no"
    if [[ -n "${branch}" ]]; then
      case "$(branch_verdict "${branch}" "${current_branch}" "${merged_heads}" "${open_heads}" "${gh_ok}" "")" in
        shipped) contained="yes" ;;
      esac
    fi

    verdict="$(classify_worktree "${path_exists}" "${is_main}" "${dirty}" "${contained}")"
    case "${verdict}" in
      keep-main) ;;
      prunable)
        prunable=$((prunable + 1))
        echo "  prune      ${path} (directory is gone)"
        ;;
      removable)
        removed=$((removed + 1))
        echo "  remove     ${path} [${branch}]"
        if [[ "${APPLY}" == "yes" ]]; then
          git worktree remove --force "${path}" || echo "    could not remove ${path}" >&2
        fi
        ;;
      *)
        kept=$((kept + 1))
        echo "  keep       ${path} [${branch:-detached}] (${verdict#keep-})"
        ;;
    esac
  done < <(worktree_rows)

  if [[ "${APPLY}" == "yes" && "${prunable}" -gt 0 ]]; then
    git worktree prune
  fi

  echo "  ${removed} removable, ${prunable} prunable registration(s), ${kept} kept."
  echo
}

tidy_branches() {
  local current_branch="$1" merged_heads="$2" open_heads="$3" gh_ok="$4"
  local wt_branches shipped=0 unshipped=0 protected=0 open_pr=0 in_worktree=0
  wt_branches="$(worktree_branches)"

  echo "== Local branches =="

  local total examined=0
  total="$(git for-each-ref --format='%(refname:short)' refs/heads/ | grep -c . || true)"
  echo "  Examining ${total} branch(es)..."

  local branch verdict
  local -a to_delete=()
  local -a unshipped_names=()
  while IFS= read -r branch; do
    [[ -z "${branch}" ]] && continue
    examined=$((examined + 1))
    # A run over hundreds of branches is not instant, and a silent wait is indistinguishable from a
    # hang (the first version of this script looked hung for ten minutes and was in fact working).
    if [[ $((examined % 50)) -eq 0 ]]; then
      echo "  ...${examined}/${total}"
    fi
    verdict="$(branch_verdict "${branch}" "${current_branch}" "${merged_heads}" "${open_heads}" "${gh_ok}" "${wt_branches}")"
    case "${verdict}" in
      shipped)     shipped=$((shipped + 1)); to_delete+=("${branch}") ;;
      # Named, not just counted. This is the one category a person may actually need to act on: it
      # is either genuine work in progress worth finishing, or a branch whose PR was closed without
      # merging, and a bare count says which of those it is for neither of them (L80).
      unshipped)   unshipped=$((unshipped + 1)); unshipped_names+=("${branch}") ;;
      protected)   protected=$((protected + 1)) ;;
      open-pr)     open_pr=$((open_pr + 1)); echo "  keep   ${branch} (open PR)" ;;
      in-worktree) in_worktree=$((in_worktree + 1)) ;;
    esac
  done < <(git for-each-ref --format='%(refname:short)' refs/heads/)

  local b
  for b in "${to_delete[@]:-}"; do
    [[ -z "${b}" ]] && continue
    echo "  delete ${b}"
    if [[ "${APPLY}" == "yes" ]]; then
      git branch -D "${b}" >/dev/null || echo "    could not delete ${b}" >&2
    fi
  done

  echo "  ${shipped} shipped (deletable), ${unshipped} kept as unshipped, ${open_pr} kept for an open PR, ${in_worktree} kept for a worktree, ${protected} protected."
  if [[ "${unshipped}" -gt 0 ]]; then
    echo "  Left alone, because nothing proves their work is in main:"
    for b in "${unshipped_names[@]:-}"; do
      [[ -z "${b}" ]] && continue
      echo "    ${b}"
    done
  fi
  echo
}

report_build_dir() {
  local build_dir="${REPO_ROOT}/mac/build"
  [[ -d "${build_dir}" ]] || return 0

  local size
  size="$(du -sh "${build_dir}" 2>/dev/null | cut -f1)"
  echo "== Build output =="
  echo "  mac/build is ${size}. It is derived data: deleting it loses nothing but costs a full rebuild."
  if [[ "${CLEAN_BUILD}" == "yes" ]]; then
    if [[ "${APPLY}" == "yes" ]]; then
      rm -rf "${build_dir}"
      echo "  Deleted."
    else
      echo "  Would delete it (--clean-build given)."
    fi
  else
    echo "  Left alone. Pass --clean-build to remove it."
  fi
  echo
}

# The Xcode build output belonging to worktrees that are already gone (#2585). This is the other half
# of the same accumulation: removing a worktree above reclaims everything it held EXCEPT its Xcode
# cache, because that is the one toolchain here whose cache lives outside the checkout, keyed by the
# checkout's path. Measured 2026-08-12: 148 GB, 101 of 105 folders belonging to directories that had
# already been deleted, and a volume down to 132 MiB free.
#
# Reported, never deleted, even under --apply. This script's remit is the checkout, the actual reclaim
# already runs on its own inside every scripts/test-all.sh, and delegating rather than reimplementing
# keeps one rule about what is safe to remove instead of two that can disagree.
report_derived_data() {
  echo "== Xcode build output =="
  "${SCRIPT_DIR}/reclaim-orphan-derived-data.sh" --dry-run || true
  echo "  Reclaimed automatically by every scripts/test-all.sh run. To do it now:"
  echo "    scripts/reclaim-orphan-derived-data.sh"
  echo
}

# Allow this file to be sourced by a fixture without running main, matching the convention in
# merge-when-green.sh and check-pr-ci.sh.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
