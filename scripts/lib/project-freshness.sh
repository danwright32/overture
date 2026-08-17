#!/usr/bin/env bash

# One implementation of the question every merge path asks before it lets anything reach main: is
# THIS ref's own committed mac/Overture.xcodeproj/project.pbxproj fresh against its own
# mac/project.yml (#2818).
#
# WHY IT IS SHARED. The question was asked in two places through two implementations, and
# merge-when-green.sh's own comment predicted the third caller that #2812 then added. The two had
# already drifted in a way that matters: verify-and-merge-branch.sh told a STALE file apart from a
# file whose freshness CANNOT BE JUDGED (check-pbxproj-fresh.sh exits 1 and 2 for those, deliberately,
# because only one of them is somebody's mistake), and merge-when-green.sh folded both into one
# "stale or could not be verified" sentence whose stated remedy, regenerate and commit, is wrong for
# half the cases it was shown for (L11). This rule guards what lands on main, so a fix applied to one
# copy silently leaving the other wrong is the whole cost.
#
# It is sourced, never executed: it defines functions and one constant and runs nothing.

# The generated file this is all about. Held here rather than restated per script, because it was
# spelled out separately in check-pbxproj-fresh.sh, merge-when-green.sh and verify-and-merge-branch.sh,
# and the last two both use it to build the message a person acts on.
PROJECT_FRESHNESS_PATH_REL="mac/Overture.xcodeproj/project.pbxproj"

# judge_ref_project_freshness <worktree-dir> <ref-label>: runs the freshness gate over a worktree that
# is ALREADY sitting on the ref being judged, and turns its three outcomes into a verdict plus the one
# message that is true of the outcome it got.
#
# 0 = fresh. 1 = refused, having printed why. The two refusals are kept apart on purpose: a stale file
# is an author's missing regeneration and names the fix, while an unjudgeable one is this Mac's xcodegen
# disagreeing with the pin and must never be reported as staleness, which would send someone to
# regenerate a file that is already correct.
#
# It runs the REF'S OWN copy of check-pbxproj-fresh.sh, not the copy belonging to the checkout doing
# the merging, because that script reads XCODEGEN_PINNED_VERSION from the ci-config.sh sitting beside
# it. A branch that deliberately bumps the pinned xcodegen and regenerates the project in the same
# commit is internally consistent and must pass; judged against main's older pin it would answer
# "cannot verify" and be refused for doing exactly the right thing.
judge_ref_project_freshness() {
  local dir="$1" ref="$2" status=0
  "${dir}/scripts/check-pbxproj-fresh.sh" "${dir}" || status=$?
  case "${status}" in
    0) return 0 ;;
    2)
      echo "Cannot judge ${ref}'s own ${PROJECT_FRESHNESS_PATH_REL} (the reason is above), so this run" >&2
      echo "  must not regenerate anything on top of it." >&2
      ;;
    *)
      echo "${ref} carries a stale ${PROJECT_FRESHNESS_PATH_REL} on its own tip." >&2
      echo "  That file is what lands on main, and regenerating it in this worktree would only hide it (#1368)." >&2
      echo "  Regenerate and commit it on ${ref} (cd mac && xcodegen generate), push, then rerun." >&2
      ;;
  esac
  return 1
}

# gate_branch_project_freshness <dir> <ref>...: judges each ref's OWN committed project file, on its own
# tip, BEFORE anything is merged into the worktree and before anything regenerates.
#
# This is what stops verify-and-merge-branch.sh's commit_merge_regeneration handing the tree a free pass,
# and the two together are the whole of #2812. check-pbxproj-fresh.sh is the gate that keeps a stale
# committed project file off main (#1368), and it can only answer honestly about a file nothing has
# rewritten. Asking it here, about each ref exactly as its author committed it, means any disagreement
# the post-merge hook then finds belongs to the COMBINATION: both parents were fresh for their own trees,
# so the merged tree is a third tree that neither of them could have carried a correct file for.
#
# It leaves the worktree on the commit it found it on, so a caller keeps the checkout it set up.
gate_branch_project_freshness() {
  local dir="$1"
  shift
  local start_head ref rc=0
  start_head="$(git -C "${dir}" rev-parse HEAD)"
  for ref in "$@"; do
    if ! git -C "${REPO_ROOT}" fetch --quiet origin "${ref}"; then
      echo "Could not fetch ${ref} to judge its own project file." >&2
      rc=1
      break
    fi
    if ! git -C "${dir}" checkout --force --detach "origin/${ref}" >/dev/null 2>&1; then
      echo "Could not check out ${ref} in the verify worktree to judge its own project file." >&2
      rc=1
      break
    fi
    if ! judge_ref_project_freshness "${dir}" "${ref}"; then
      rc=1
      break
    fi
  done
  git -C "${dir}" checkout --force --detach "${start_head}" >/dev/null 2>&1 || rc=1
  return "${rc}"
}
