#!/usr/bin/env bash
# One answer to "is this directory mine to scrub", asked by every merge path before it force-detaches,
# cleans, removes or deletes a worktree (#2923).
#
# WHY IT EXISTS. On 2026-08-17 a working checkout was moved off an in-progress feature branch onto main
# without being asked. The visible cost was not the inconvenience: a full scripts/test-all.sh run made
# straight afterwards verified main while everyone believed it was verifying the branch, and that pass
# was written into a PR body as evidence for code it had never compiled (L98, L70). A
# `git push -u origin <branch>` then pushed main's HEAD at the feature branch's name and was refused
# only by luck of the ref ordering.
#
# That instance was mac/scripts/lib/update-sync.sh, fixed in its own file. This is the CLASS. Derived
# from `grep -rn 'checkout' scripts/*.sh scripts/lib/*.sh`, two other places move a checkout's HEAD:
#
#   scripts/verify-and-merge-branch.sh  setup_worktree, over ${OVERTURE_VERIFY_WORKTREE:-~/.overture-verify-worktree}
#   scripts/lib/project-freshness.sh    gate_branch_project_freshness, over whatever dir its caller hands it
#
# Neither aims at a working checkout today, and neither would notice if it did. Both take their target
# from an environment variable or a caller's argument; the first force-detaches it, runs
# `git clean -ffdx` over it, and on the fallback path deletes the directory outright, and the second
# force-detaches it and restores it to a bare SHA, so even its restore drops the branch attachment.
# Nothing between an exported variable and any of that asked a single question.
#
# HOW IT TELLS THEM APART, and why it is evidence rather than a naming convention. The verify slot is
# created with `git worktree add --detach` and is detached for its whole life. A directory standing on a
# NAMED branch is therefore somebody's working checkout, whatever it is called and wherever it was
# pointed. That question is asked independently of "is this REPO_ROOT", so neither side answers for the
# other (L70): the working checkout is refused even while detached, which is exactly the state a
# previous run of one of these functions could have left it in.
#
# It is sourced, never executed: it defines two functions and runs nothing.

# scratch_worktree_verdict PATH_EXISTS IS_WORKING_CHECKOUT HEAD_BRANCH
#   IS_WORKING_CHECKOUT is yes, no, or unknown. Prints one of:
#     scratch                   nothing there, or a detached worktree this may scrub
#     refuse:working-checkout   this is the checkout the script itself is running from
#     refuse:cannot-tell        the comparison could not be made at all
#     refuse:on-a-branch        something is standing on a named branch in there
#
# HEAD_BRANCH is what `git rev-parse --abbrev-ref HEAD` prints: a branch name, the literal HEAD when
# detached, or empty when the directory is not a git worktree at all.
#
# The working-checkout question is asked FIRST, so the safe answer never depends on which of two true
# things is checked first, and so the refusal names what the directory IS rather than where it happens
# to be standing. `unknown` is its own word rather than being folded into `yes`, because the message a
# person acts on would otherwise state as measured fact something nothing measured (L11).
scratch_worktree_verdict() {
  local path_exists="${1:-yes}" is_working_checkout="${2:-unknown}" head_branch="${3:-}"

  [[ "${is_working_checkout}" == "yes" ]] && { printf 'refuse:working-checkout\n'; return 0; }
  [[ "${is_working_checkout}" != "no" ]] && { printf 'refuse:cannot-tell\n'; return 0; }
  [[ "${path_exists}" != "yes" ]] && { printf 'scratch\n'; return 0; }
  [[ -z "${head_branch}" || "${head_branch}" == "HEAD" ]] && { printf 'scratch\n'; return 0; }
  printf 'refuse:on-a-branch\n'
  return 0
}

# require_scratch_worktree <dir> <repo-root> <what-would-have-happened>
#   Gathers the two facts and returns 0 when <dir> may be scrubbed, or 1 having said why.
#
# The refusal names the directory, the branch when there is one, and the operation it stopped, because
# the whole shape of #2923 was a checkout that moved with nothing anywhere saying it had (L148): the
# switch was found from the reflog, days later, and only because an unrelated later step failed.
#
# Both paths resolve with `cd ... && pwd -P`, so a symlinked or trailing-slash spelling of the same
# directory cannot walk past the comparison.
require_scratch_worktree() {
  local dir="${1:-}" repo_root="${2:-}" what="${3:-this operation}"
  local path_exists=no is_working_checkout=no head_branch="" resolved_dir="" resolved_root=""

  if [[ -d "${dir}" ]]; then
    path_exists=yes
    resolved_dir="$(cd "${dir}" 2>/dev/null && pwd -P || echo "")"
    head_branch="$(git -C "${dir}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  fi
  if [[ -d "${repo_root}" ]]; then
    resolved_root="$(cd "${repo_root}" 2>/dev/null && pwd -P || echo "")"
  fi
  # An unresolvable pair is never read as "different": it would be the one comparison whose failure
  # points at the destructive answer. It is `unknown` rather than `yes`, because the two get different
  # messages and only one of them is something this actually measured.
  if [[ -z "${resolved_dir}" && "${path_exists}" == "yes" ]] || [[ -z "${resolved_root}" ]]; then
    is_working_checkout=unknown
  elif [[ "${resolved_dir}" == "${resolved_root}" ]]; then
    is_working_checkout=yes
  fi

  case "$(scratch_worktree_verdict "${path_exists}" "${is_working_checkout}" "${head_branch}")" in
    scratch) return 0 ;;
    refuse:working-checkout)
      echo "Refusing to use ${dir} as a throwaway worktree: it is the checkout this script is running from." >&2
      echo "  ${what} would have force-detached it, cleaned it, or deleted it outright, and any work in it" >&2
      echo "  would have gone with no trace but the reflog (#2923). Nothing was done to it." >&2
      return 1
      ;;
    refuse:cannot-tell)
      echo "Refusing to use ${dir} as a throwaway worktree: it could not be compared against the checkout" >&2
      echo "  this script is running from (one of the two paths would not resolve). That is not the same" >&2
      echo "  claim as it being that checkout, and it is not evidence of being anything else either, so" >&2
      echo "  ${what} is refused rather than guessed at (#2923). Nothing was done to it." >&2
      return 1
      ;;
    *)
      echo "Refusing to use ${dir} as a throwaway worktree: it is standing on the branch ${head_branch}." >&2
      echo "  The verify slot is detached for the whole of its life, so a named branch here means somebody" >&2
      echo "  is working in this directory. ${what} would have moved it off that branch (#2923)." >&2
      echo "  Nothing was done to it. Point OVERTURE_VERIFY_WORKTREE somewhere of its own, or leave it unset." >&2
      return 1
      ;;
  esac
}
