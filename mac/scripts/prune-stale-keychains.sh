#!/usr/bin/env bash
set -uo pipefail

# Removes entries from the USER's keychain search list whose file no longer exists (#2611), and says
# what it did.
#
# What it was written for. Measured 2026-08-13, `security list-keychains` on this Mac held four
# entries, one of them a THROWAWAY keychain under a temp directory that had long since gone:
#
#     /private/var/folders/kd/.../T/tmp.uIH2OYGQWw/throwaway.keychain-db
#
# Something in this repo's tooling put it in a persistent OS level resource outside the checkout and
# nothing took it out again when the temp directory went away. It is the same shape as #2585 and
# L114: a tool that creates a throwaway workspace must also remove what that workspace caused to be
# created outside it.
#
# It breaks nothing today, which is why the issue is p3: an entry pointing at a missing file is
# skipped, and `security find-identity -v -p codesigning` resolves every real identity, Overture's
# included. It matters because it is state that makes the next diagnosis harder in exactly the area
# that has already produced #1425, #1525, #1526 and #2537.
#
# Deliberately NOT wired into scripts/test-all.sh. Every other advisory that rides along there reads
# or clears something this repo created (LaunchServices registrations for Overture bundles, Xcode
# folders for worktrees that are gone). This writes the user's keychain search list, which is shared
# with every other tool on this Mac, and a write like that belongs behind a command somebody typed.
#
# Usage:
#   mac/scripts/prune-stale-keychains.sh              # remove the stale entries and say so
#   mac/scripts/prune-stale-keychains.sh --dry-run    # report them and change nothing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/keychain-search-list.sh
source "${SCRIPT_DIR}/lib/keychain-search-list.sh"

DRY_RUN="no"

usage() {
  echo "Usage: mac/scripts/prune-stale-keychains.sh [--dry-run]" >&2
  exit 2
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN="yes"; shift ;;
      -h|--help) usage ;;
      *)         echo "Unknown argument: $1" >&2; usage ;;
    esac
  done

  local listing paths keep gone verdict path
  # Fail loud rather than reporting a clean search list that was never read (L11). An empty answer
  # here would otherwise be indistinguishable from a list with nothing in it, and the only thing this
  # script can do with an empty list is refuse.
  if ! listing="$(security list-keychains -d user 2>/dev/null)"; then
    echo "prune-stale-keychains: could not read the user keychain search list. Nothing was changed." >&2
    return 0
  fi

  paths="$(keychain_search_list_paths "${listing}")"
  keep="$(keychain_paths_present "${paths}")"
  gone="$(keychain_paths_missing "${paths}")"
  verdict="$(keychain_rewrite_verdict "${keep}" "${gone}")"

  case "${verdict}" in
    nothing-to-do)
      echo "prune-stale-keychains: nothing stale. Every entry in the user search list points at a file that exists."
      return 0
      ;;
    refuse)
      echo "prune-stale-keychains: REFUSING to write. Not one entry in the search list points at a file" >&2
      echo "that exists, which is what an unreadable listing looks like as well as an empty one, and the" >&2
      echo "only way to change this list is to write the whole of it back. Left alone. Read it with:" >&2
      echo "  security list-keychains -d user" >&2
      return 0
      ;;
  esac

  echo "prune-stale-keychains: these entries point at files that are gone:"
  while IFS= read -r path; do
    [[ -n "${path}" ]] && echo "  ${path}"
  done <<< "${gone}"

  if [[ "${DRY_RUN}" == "yes" ]]; then
    echo "Dry run: nothing was changed. Rerun without --dry-run to remove them."
    return 0
  fi

  # The whole list is written back, minus those, in the order it was in. Word splitting on the
  # newline-separated survivors is what turns them into separate arguments, and IFS is set for this
  # one command only.
  local -a keep_args=()
  while IFS= read -r path; do
    [[ -n "${path}" ]] && keep_args+=("${path}")
  done <<< "${keep}"

  if security list-keychains -d user -s ${keep_args[@]+"${keep_args[@]}"}; then
    echo "Removed. The user search list now holds only the entries whose files exist:"
    for path in ${keep_args[@]+"${keep_args[@]}"}; do
      echo "  ${path}"
    done
  else
    echo "prune-stale-keychains: the rewrite FAILED, so the search list is whatever it was before." >&2
    echo "Read it with: security list-keychains -d user" >&2
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
