#!/usr/bin/env bash
set -euo pipefail

# One-time, idempotent per-clone setup: point git at this repo's tracked hooks (scripts/hooks) so the
# post-merge pbxproj helper (#1251 Phase 3) runs. Per-clone because core.hooksPath lives in .git/config,
# which is not tracked, so each clone/worktree needs it once (documented in AGENTS.md). Safe to re-run.
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
  echo "Installed: core.hooksPath=scripts/hooks for this clone. The post-merge pbxproj helper is now active."
fi
