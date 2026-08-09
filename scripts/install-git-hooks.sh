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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  chmod +x "${SCRIPT_DIR}/hooks/"* 2>/dev/null || true
  install_hooks_into "${REPO_ROOT}"
  echo "Installed: core.hooksPath=scripts/hooks for this clone."
  echo "  post-merge: regenerates a stale pbxproj after a merge that combined Mac source changes."
  echo "  pre-push:   refuses a push straight to main (override once with ALLOW_PUSH_TO_MAIN=1)."
fi
