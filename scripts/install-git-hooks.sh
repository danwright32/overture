#!/usr/bin/env bash
set -euo pipefail

# One-time, idempotent per-clone setup: point git at this repo's tracked hooks (scripts/hooks), which are
# the post-merge pbxproj helper (#1251 Phase 3) and the pre-push guard that refuses a push straight to main
# (#2291). Per-clone because core.hooksPath lives in .git/config, which is not tracked, so each
# clone/worktree needs it once (documented in AGENTS.md). Safe to re-run.
#
# The per-clone step is narrower than it looks: core.hooksPath lives in the SHARED git config (this repo
# sets no extensions.worktreeConfig), so every worktree inherits it from the main checkout without running
# this again. #2291's proposed GitHub branch protection was declined on 2026-08-09 on that measurement,
# and is a decision rather than an outstanding to-do. See AGENTS.md.
#
# Usage: scripts/install-git-hooks.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Points git at scripts/hooks for the given repo. Idempotent: core.hooksPath is a single value git
# overwrites, so re-running never appends a duplicate. Extracted so a fixture can drive it against a
# throwaway git repo without touching this clone's config.
install_hooks_into() {
  local repo_dir="$1"
  git -C "${repo_dir}" config core.hooksPath scripts/hooks
}

# Registers the merge driver that `.gitattributes` sends this repo's two generated files to (#2557).
# Same per-clone reason as core.hooksPath above: merge.<name>.driver lives in the git config, which is
# not tracked, and which every worktree of this clone shares. Idempotent for the same reason too, since
# git overwrites a single-valued key rather than appending.
#
# `%O %A %B %L %P` is git's own argument order (ancestor, ours, theirs, marker size, path). The path is
# what lets the driver refuse a file it does not own instead of resolving whatever it is handed.
install_generated_merge_driver_into() {
  local repo_dir="$1"
  git -C "${repo_dir}" config merge.overture-generated.name \
    "keep either side of a generated file; the freshness gate regenerates it"
  git -C "${repo_dir}" config merge.overture-generated.driver \
    "scripts/lib/merge-generated.sh %O %A %B %L %P"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  chmod +x "${SCRIPT_DIR}/hooks/"* 2>/dev/null || true
  chmod +x "${SCRIPT_DIR}/lib/merge-generated.sh" 2>/dev/null || true
  install_hooks_into "${REPO_ROOT}"
  install_generated_merge_driver_into "${REPO_ROOT}"
  echo "Installed: core.hooksPath=scripts/hooks for this clone."
  echo "  post-merge: regenerates a stale pbxproj after a merge that combined Mac source changes."
  echo "  pre-push:   refuses a push straight to main (override once with ALLOW_PUSH_TO_MAIN=1)."
  echo "Installed: merge driver overture-generated for this clone."
  echo "  Resolves a conflict in docs/copy-inventory.md or mac/Overture.xcodeproj/project.pbxproj,"
  echo "  which are generated, and leaves every other conflict to be read. scripts/test-all.sh is"
  echo "  still what settles their content."
fi
