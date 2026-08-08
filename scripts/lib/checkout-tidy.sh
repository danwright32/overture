#!/usr/bin/env bash
# Decisions about what in this checkout may be deleted (#2234). Pure functions only: nothing here
# runs git, gh, or touches the filesystem, so tidy-checkout.sh and the merge scripts share one
# implementation of "is this safe to remove" and a fixture can exercise every branch of it.
#
# Why this file exists at all: the standard cleanup idiom, `git branch --merged main -d`, cannot
# work in this repo. Every branch is SQUASH-merged, so a fully shipped branch is never an ancestor
# of main. Measured 2026-08-06: 496 local branches, of which git recognised 39 as merged. Anyone
# running the standard command would watch it delete almost nothing and reasonably conclude there
# was nothing to delete, which is exactly what happened for months.
#
# Two tests replace it, and a branch only has to pass ONE:
#   * `git cherry main <branch>` asks whether each commit's PATCH is already present in main, which
#     survives a rebase and a cherry-pick but NOT a squash (a squashed commit's patch-id matches the
#     combined diff, not any individual commit's).
#   * A merged PR with that head branch, which is what covers the squashed case.
# Both fail in the safe direction: an unreadable answer keeps the branch.

# True when `git cherry main <branch>` proves main already carries every one of the branch's
# patches. Empty output means the branch has no commits main lacks. Otherwise every line must be a
# "-" line (patch present); a single "+" (missing), or any line in a shape git cherry does not
# produce, means no.
cherry_says_contained() {
  local cherry_output="$1"

  [[ -z "${cherry_output}" ]] && return 0

  local line
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    [[ "${line}" == "- "* ]] || return 1
  done <<< "${cherry_output}"
  return 0
}

# Everything that can be decided about a branch WITHOUT running `git cherry`, printed as a single
# word: protected, in-worktree, open-pr, shipped, or needs-cherry.
#
# It is split out because `git cherry` is by far the expensive part (it computes a patch-id for
# every commit on the branch, and there are hundreds of branches), and because the caller cannot
# avoid that cost by any check placed INSIDE classify_branch: the shell evaluates the argument
# before the call, so a cherry passed in as a parameter has already been paid for (L62). The cheap
# question therefore has to be askable on its own, at the call site.
#
# The order is the point. Protection is checked before any evidence of shipping, so no amount of
# "this already landed" can talk the script into deleting something in use. An open PR outranks
# shipped for the same reason: a branch can have every patch in main and still be the head of a
# live PR, and pulling the ref out from under it helps nobody.
#
# merged_pr_count and open_pr_count come from gh and may be EMPTY, which means gh could not answer
# (offline, unauthenticated, rate limited). Empty is never read as zero: it simply falls through to
# cherry as the only evidence, and cherry can only ever move a branch toward being kept.
classify_branch_before_cherry() {
  local branch="$1" current_branch="$2"
  local merged_pr_count="$3" open_pr_count="$4" worktree_branches="$5"

  if [[ -z "${branch}" || "${branch}" == "main" || "${branch}" == "master" || "${branch}" == "${current_branch}" ]]; then
    echo "protected"
    return 0
  fi

  if branch_in_list "${branch}" "${worktree_branches}"; then
    echo "in-worktree"
    return 0
  fi

  if [[ "${open_pr_count}" =~ ^[0-9]+$ ]] && [[ "${open_pr_count}" -gt 0 ]]; then
    echo "open-pr"
    return 0
  fi

  if [[ "${merged_pr_count}" =~ ^[0-9]+$ ]] && [[ "${merged_pr_count}" -gt 0 ]]; then
    echo "shipped"
    return 0
  fi

  echo "needs-cherry"
}

# The full verdict for one local branch: whatever the cheap pass decided, or else what cherry says.
# One word: protected, in-worktree, open-pr, shipped, or unshipped. The ordering lives once, in
# classify_branch_before_cherry, so the fast path the driver takes and the whole decision tested
# here cannot disagree about precedence.
classify_branch() {
  local branch="$1" current_branch="$2" cherry_output="$3"
  local merged_pr_count="$4" open_pr_count="$5" worktree_branches="$6"

  local early
  early="$(classify_branch_before_cherry "${branch}" "${current_branch}" \
    "${merged_pr_count}" "${open_pr_count}" "${worktree_branches}")"
  if [[ "${early}" != "needs-cherry" ]]; then
    echo "${early}"
    return 0
  fi

  if cherry_says_contained "${cherry_output}"; then
    echo "shipped"
    return 0
  fi

  echo "unshipped"
}

# The verdict for one registered worktree, printed as a single word:
#   keep-main       this repo's own working copy
#   prunable        registered against a directory that no longer exists (git worktree prune's job)
#   keep-dirty      holds uncommitted work
#   keep-unshipped  clean, but its branch's work is not provably in main
#   removable       clean, and its branch shipped
#
# Dirty is checked before containment deliberately. An agent worktree is only auto-removed when it
# made NO changes, so the ones that survive are precisely the ones that did real work, and a shipped
# branch says nothing about the uncommitted edits sitting on top of it.
classify_worktree() {
  local path_exists="$1" is_main="$2" dirty="$3" contained="$4"

  [[ "${is_main}" == "yes" ]] && { echo "keep-main"; return 0; }
  [[ "${path_exists}" == "yes" ]] || { echo "prunable"; return 0; }
  [[ "${dirty}" == "yes" ]] && { echo "keep-dirty"; return 0; }
  [[ "${contained}" == "yes" ]] || { echo "keep-unshipped"; return 0; }
  echo "removable"
}

# The verdict for the local branch of a PR that has JUST been merged, printed as a single word:
# deletable, protected, or in-worktree. Containment is not in question here (the merge is the
# proof), so the only remaining question is whether the ref is in use. This is where the leak
# actually starts: `gh pr merge --delete-branch` removes the REMOTE branch and leaves the local one
# behind forever, which is how 496 of them accumulated.
local_branch_deletable() {
  local branch="$1" current_branch="$2" worktree_branches="$3"

  if [[ -z "${branch}" || "${branch}" == "main" || "${branch}" == "master" || "${branch}" == "${current_branch}" ]]; then
    echo "protected"
    return 0
  fi

  if branch_in_list "${branch}" "${worktree_branches}"; then
    echo "in-worktree"
    return 0
  fi

  echo "deletable"
}

# Whole-line membership of a newline-separated list. Substring matching would be a live hazard here:
# every branch in this repo is named after an issue, so "1234-fix" is a substring of "1234-fix-again"
# and a careless match would silently protect (or condemn) the wrong branch.
branch_in_list() {
  local needle="$1" list="$2"
  [[ -z "${needle}" ]] && return 1
  local line
  while IFS= read -r line; do
    [[ "${line}" == "${needle}" ]] && return 0
  done <<< "${list}"
  return 1
}

# ---------------------------------------------------------------------------
# The one function below this line touches git. Everything above is pure.
# ---------------------------------------------------------------------------

# Deletes the local ref of a branch whose PR has just been merged, and says what it did. Called by
# both merge scripts, which is where the branch backlog actually comes from: `gh pr merge
# --delete-branch` deletes the branch on GitHub and leaves the local one behind forever.
#
# Never fatal. The merge has already happened by the time this runs, so a failure to tidy up must
# not be reported as a failed merge (L12: report what verifiably happened, and what happened is a
# successful merge plus a leftover ref).
delete_merged_local_branch() {
  local branch="$1"
  local current_branch worktree_branches verdict

  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  worktree_branches="$(git worktree list --porcelain 2>/dev/null | sed -n 's|^branch refs/heads/||p' || echo "")"

  verdict="$(local_branch_deletable "${branch}" "${current_branch}" "${worktree_branches}")"
  case "${verdict}" in
    deletable)
      if git branch -D "${branch}" >/dev/null 2>&1; then
        echo "Deleted the local branch ${branch}."
      else
        echo "Merged, but could not delete the local branch ${branch}. Run scripts/tidy-checkout.sh later."
      fi
      ;;
    in-worktree)
      echo "Left the local branch ${branch} alone: a worktree still has it checked out."
      ;;
    protected)
      echo "Left the local branch ${branch:-(unknown)} alone: it is checked out here, or is not a branch this may delete."
      ;;
  esac
}
