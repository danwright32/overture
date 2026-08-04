#!/usr/bin/env bash
set -euo pipefail

# #1808: record the newest commit on main, so the app can tell Dan when the copy he is looking at is
# behind it. The app cannot run git, so this is the only way it ever learns what has shipped.
#
# ONE writer for `shipped-commit.json`, called from every place a merge can land on this Mac:
#   - scripts/merge-when-green.sh and scripts/verify-and-merge-branch.sh, after a successful merge
#   - scripts/hooks/post-merge, so a plain `git pull` on main counts too
#   - mac/build-install.sh, so a freshly installed Mac never sits in the "nothing has recorded a merge"
#     state, which would show Dan a panel he has no way to clear
#
# It reads origin/main, not the local branch, because "what has shipped" is a fact about the remote and
# the caller is routinely somewhere else: merge-when-green.sh merges on GitHub and is standing on the
# feature branch when it returns, so local main is a commit behind at exactly the moment this runs.
#
# The honest hole, named rather than engineered around: if the fetch fails (offline), it records whatever
# origin/main last pointed at, which may be behind. A stale record makes the app say "up to date" when it
# is not, which is the quiet direction of failure. It self-corrects on the next successful call, and
# every caller is an action that is online anyway (a merge, an install).
#
# Writes into the RELEASE data directory, which is where the installed app reads it. A Debug run reads
# its own folder and so never sees this file, which is right: a Debug build is not the installed copy and
# has no business being told it is out of date.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${HOME}/Library/Application Support/Overture"
RECORD="${DATA_DIR}/shipped-commit.json"

# The record's exact bytes, given a commit and its date. Pure, so scripts/record-shipped-commit.test.sh
# can pin the shape docs/contracts.md documents without writing into anyone's Application Support.
shipped_commit_json() {
  local commit="$1" commit_date="$2"
  printf '{"version":1,"commit":"%s","commitDate":"%s"}\n' "${commit}" "${commit_date}"
}

main() {
  local commit commit_date
  git -C "${REPO_ROOT}" fetch --quiet origin main 2>/dev/null \
    || echo "record-shipped-commit: could not fetch; recording the last known origin/main." >&2

  if ! commit="$(git -C "${REPO_ROOT}" rev-parse origin/main 2>/dev/null)"; then
    echo "record-shipped-commit: no origin/main to read; nothing recorded." >&2
    exit 0
  fi
  # %cI is the COMMITTER date in strict ISO 8601, which is what the app decodes. Committer, not author:
  # a squash merge rewrites the committer date to the merge, which is when the work actually shipped.
  commit_date="$(git -C "${REPO_ROOT}" log -1 --format=%cI "${commit}")"

  mkdir -p "${DATA_DIR}"
  # Written to a temp file and moved into place, so a reader can never catch a half-written record and
  # decide from it (L5). The move is atomic within one filesystem.
  local tmp
  tmp="$(mktemp "${DATA_DIR}/.shipped-commit.XXXXXX")"
  shipped_commit_json "${commit}" "${commit_date}" > "${tmp}"
  mv -f "${tmp}" "${RECORD}"
  echo "record-shipped-commit: recorded ${commit:0:7} (${commit_date})."
}

# Sourceable without running, so the fixture can exercise shipped_commit_json directly. Mirrors
# merge-when-green.sh's convention.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
