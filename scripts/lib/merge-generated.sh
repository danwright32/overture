#!/usr/bin/env bash
set -euo pipefail

# The git merge driver for this repo's two GENERATED files (#2557).
#
# `docs/copy-inventory.md` and `mac/Overture.xcodeproj/project.pbxproj` are both produced from the
# source, so any two branches that touch the app's wording or its file list conflict on them by
# construction. Neither side's text is anybody's to write, and a three way text merge of a generated
# file is a question with no answer in it. Measured 2026-08-11: two branches in a row each conflicted on
# the inventory against a main that had moved, roughly twelve minutes apiece, and neither conflict
# carried a single decision.
#
# WHAT THIS DOES, and the part worth reading before changing it: it resolves the conflict to one side
# and does NOT regenerate. Regenerating here would be the obvious move and it would be wrong. Git runs a
# merge driver per file, WHILE the merge is in progress, so the worktree it would read is not the merged
# tree: other files may still be unmerged or not yet written. A generator run at that moment produces
# output derived from a state that never existed, and it would look exactly as authoritative as a
# correct one. So the driver's whole job is to remove a conflict that carries no decision, and the
# freshness gates settle the content afterwards, on the complete tree, where the answer is real:
#
#   - `scripts/check-pbxproj-fresh.sh` BLOCKS on a stale project file. It rides along in
#     `scripts/test-all.sh` and both merge scripts run it.
#   - `CopyInventoryTests` fails the Swift suite on a stale inventory and names the sentences that moved.
#   - `scripts/hooks/post-merge` regenerates a stale project file after a merge and stages it.
#
# That is the same division the issue asks for: the gate stays the real check, and this only removes a
# conflict nobody could have resolved by reading it.
#
# Git calls it as: driver %O %A %B %L %P
#   %O the common ancestor's version, %A ours (and where the result must be written), %B theirs,
#   %L the conflict marker size, %P the path in the repo.
# Exit 0 means resolved, nonzero means leave it conflicted.

# The paths this driver owns. `.gitattributes` sends exactly these here, and
# `scripts/lib/merge-generated.test.sh` reads this list rather than repeating it, so the two cannot
# drift apart (L41).
GENERATED_PATHS=(
  "docs/copy-inventory.md"
  "mac/Overture.xcodeproj/project.pbxproj"
)

print_generated_paths() {
  printf '%s\n' "${GENERATED_PATHS[@]}"
}

# Refuses anything outside the pair. A driver that resolves whatever it is pointed at turns one mistyped
# `.gitattributes` line into a silent loss of somebody's work, and nothing downstream would ever report
# it: the merge would simply look clean. Failing closed here means the worst a bad line can do is leave
# a conflict for a person to read (L42).
main() {
  local ours="${2:-}" path="${5:-}"

  if [[ -z "${path}" ]]; then
    echo "merge-generated: called with no path, so it cannot tell whether it owns this file." >&2
    echo "  Expected git's merge driver arguments: %O %A %B %L %P" >&2
    return 1
  fi

  local owned
  for owned in "${GENERATED_PATHS[@]}"; do
    if [[ "${path}" == "${owned}" ]]; then
      # `ours` already holds our side's content, so keeping it is doing nothing to the file on purpose.
      # Said out loud rather than done silently, because a merge that resolves a file without mentioning
      # it is indistinguishable from one that had no conflict at all.
      echo "merge-generated: ${path} is generated, so this conflict carries no decision. Kept one side."
      echo "  It is regenerated from the merged tree, not from here: run scripts/test-all.sh, which"
      echo "  blocks on a stale project file and fails on a stale copy inventory."
      [[ -f "${ours}" ]] || return 1
      return 0
    fi
  done

  echo "merge-generated: refusing ${path}, which is not one of this repo's generated files." >&2
  echo "  Leaving the conflict in place to be read. The generated files are:" >&2
  printf '    %s\n' "${GENERATED_PATHS[@]}" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "${1:-}" == "--paths" ]]; then
    print_generated_paths
    exit 0
  fi
  main "$@"
fi
