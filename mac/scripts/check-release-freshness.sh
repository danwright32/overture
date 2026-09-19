#!/usr/bin/env bash
set -euo pipefail

# #1345: tell at a glance whether the installed Release app is BEHIND the code. Three times in one session
# an issue looked unbuilt when the work had shipped, because /Applications/Overture.app predated the merged
# code. "Is this a stale build?" is the first question for any "it looks unbuilt / a UI bug" report, and
# there was no quick signal. This compares the installed app's build time to the latest commit's time; if
# the app was built BEFORE the newest commit, it may be missing merged work, so it says so and points at
# build-install.sh.
#
# Deliberately build-time vs commit-time, not a git sha: it works on the app ALREADY installed today with
# no rebuild. The one blind spot is honest and harmless: a rebuild with no new commits reads as fresh,
# which it is. Exits 1 when stale so a caller can gate on it; 0 when fresh or not installed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# Both overridable so the fixture can drive main() against a throwaway repository and a stand-in app,
# rather than against /Applications and this checkout (L2).
INSTALLED_APP_BIN="${OVERTURE_INSTALLED_APP_BIN:-/Applications/Overture.app/Contents/MacOS/Overture}"
FRESHNESS_REPO="${OVERTURE_FRESHNESS_REPO:-${REPO_ROOT}}"

# freshness_verdict <installed_build_epoch> <latest_commit_epoch>. Prints "stale" when the app was built
# BEFORE the latest commit (so it may be missing merged work), else "fresh". Equal times are fresh: a build
# carries the commit it was built from, so building exactly at a commit is not "behind" it.
freshness_verdict() {
  local installed_epoch="$1" latest_commit_epoch="$2"
  if [[ "${installed_epoch}" -lt "${latest_commit_epoch}" ]]; then
    echo "stale"
  else
    echo "fresh"
  fi
}

# #3929: the commit the installed app is judged against is the newest one SHIPPED, never whatever the
# checkout running this happens to have.
#
# It used to be `git log -1 HEAD` of this script's own checkout. `merge_pr` calls this the moment a PR
# merges, and the checkout it runs from is usually the primary one, still on the main from before the
# merge. Measured 2026-09-15: PR #3928 merged at 15:42 and this printed "Installed Release is up to date:
# built 2026-09-15 14:37, at or after the latest commit (2026-09-15 12:18)". The app did not contain the
# fix it had just called current. This is the one line somebody reads to decide whether a merged fix is
# on Dan's machine, so a false "up to date" is worse than no line at all (L454, L398).
#
# So: refresh origin/main first and judge against THAT, and name the revision in the output, so a
# comparison that could not be refreshed is visible rather than silently stale. The fetch carries
# build-provenance.sh's stall caps, since this runs inside a merge and is never worth hanging one.
#
# latest_shipped_commit <repo-root>. Prints "<epoch> <short sha> <label>", where the label says which
# revision was read and whether it could be refreshed. Prints nothing when no revision could be read.
latest_shipped_commit() {
  local repo="$1" ref label line
  if GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=20 \
     git -C "${repo}" fetch --quiet origin main >/dev/null 2>&1; then
    ref="origin/main"
    label="origin/main"
  elif git -C "${repo}" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
    ref="origin/main"
    label="origin/main as last fetched (the refresh FAILED, so newer merges may be missing)"
  else
    ref="HEAD"
    label="this checkout's HEAD (there is no origin/main to read, so this is NOT the shipped code)"
  fi
  line="$(git -C "${repo}" log -1 --format='%ct %h' "${ref}" 2>/dev/null)" || return 0
  [[ -n "${line}" ]] || return 0
  echo "${line} ${label}"
}

main() {
  if [[ ! -e "${INSTALLED_APP_BIN}" ]]; then
    echo "Overture is not installed at /Applications/Overture.app (nothing to compare). Build it with mac/build-install.sh."
    exit 0
  fi

  local installed_epoch commit_epoch verdict shipped commit_sha compared
  installed_epoch="$(stat -f %m "${INSTALLED_APP_BIN}")"
  shipped="$(latest_shipped_commit "${FRESHNESS_REPO}")"
  if [[ -z "${shipped}" ]]; then
    # Said rather than guessed: with no revision to compare against there is no verdict, and "up to date"
    # would be the one wrong answer this line exists to avoid.
    echo "Could NOT judge the installed Release: no commit could be read from ${FRESHNESS_REPO}."
    exit 0
  fi
  commit_epoch="${shipped%% *}"
  shipped="${shipped#* }"
  commit_sha="${shipped%% *}"
  compared="${shipped#* }"

  verdict="$(freshness_verdict "${installed_epoch}" "${commit_epoch}")"
  local installed_when latest_when
  installed_when="$(date -r "${installed_epoch}" '+%Y-%m-%d %H:%M')"
  latest_when="$(date -r "${commit_epoch}" '+%Y-%m-%d %H:%M')"

  if [[ "${verdict}" == "stale" ]]; then
    echo "Installed Release is BEHIND the code: built ${installed_when}, but the latest commit on ${compared} is ${commit_sha} at ${latest_when}."
    echo "It may be missing merged work. Rebuild with mac/build-install.sh, then relaunch."
    exit 1
  fi
  echo "Installed Release is up to date: built ${installed_when}, at or after the latest commit on ${compared} (${commit_sha}, ${latest_when})."
  exit 0
}

# Allow this file to be sourced (e.g. by a test fixture) without running main, so freshness_verdict can be
# exercised directly. Mirrors run-tests-locked.sh's convention.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
