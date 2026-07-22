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
INSTALLED_APP_BIN="/Applications/Overture.app/Contents/MacOS/Overture"

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

main() {
  if [[ ! -e "${INSTALLED_APP_BIN}" ]]; then
    echo "Overture is not installed at /Applications/Overture.app (nothing to compare). Build it with mac/build-install.sh."
    exit 0
  fi

  local installed_epoch commit_epoch verdict
  installed_epoch="$(stat -f %m "${INSTALLED_APP_BIN}")"
  commit_epoch="$(git -C "${REPO_ROOT}" log -1 --format=%ct HEAD)"

  verdict="$(freshness_verdict "${installed_epoch}" "${commit_epoch}")"
  local installed_when latest_when
  installed_when="$(date -r "${installed_epoch}" '+%Y-%m-%d %H:%M')"
  latest_when="$(date -r "${commit_epoch}" '+%Y-%m-%d %H:%M')"

  if [[ "${verdict}" == "stale" ]]; then
    echo "Installed Release is BEHIND the code: built ${installed_when}, but the latest commit is ${latest_when}."
    echo "It may be missing merged work. Rebuild with mac/build-install.sh, then relaunch."
    exit 1
  fi
  echo "Installed Release is up to date: built ${installed_when}, at or after the latest commit (${latest_when})."
  exit 0
}

# Allow this file to be sourced (e.g. by a test fixture) without running main, so freshness_verdict can be
# exercised directly. Mirrors run-tests-locked.sh's convention.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
