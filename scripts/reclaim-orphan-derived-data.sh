#!/usr/bin/env bash
set -uo pipefail

# #2585: delete the Xcode build folders that belong to worktrees which no longer exist, and say how
# much room is left.
#
# Xcode keys DerivedData by the workspace's PATH, so every worktree that is ever built mints a fresh
# folder of roughly 1.6 GB and nothing reclaims it when the worktree goes. This repo makes those paths
# constantly (one per parallel agent; pre-merge verification stopped minting when #2601 gave it one
# persistent worktree), so the growth
# is proportional to how much the workflow is used and its ceiling is the disk. On 2026-08-12 it reached
# that ceiling: 148 GB in DerivedData, 101 of 105 folders pointing at deleted directories, 132 MiB free
# on a 926 GiB volume, and no command able to run at all, including `df`.
#
# It takes no arguments in the ordinary case: it removes them and says how many. Same reasoning as
# mac/scripts/prune-stale-registrations.sh, and Dan's call again on 2026-08-12, so there is no
# count-only mode to choose between and nothing to remember to run.
#
# It can only ever delete a folder whose workspace is GONE from disk (scripts/lib/derived-data.sh owns
# that rule), which means nobody pays a rebuild for anything it takes. The three SHARED caches are a
# different question, because clearing them does cost every project on this Mac one slow build, so they
# are only counted here unless --clear-shared-caches is typed deliberately.
#
# Never blocking. It rides along in scripts/test-all.sh, and a Mac that will not let a folder be deleted
# is not a defect in the change being pushed.
#
# Usage:
#   scripts/reclaim-orphan-derived-data.sh                        # reclaim the dead folders
#   scripts/reclaim-orphan-derived-data.sh --dry-run              # report them, delete nothing
#   scripts/reclaim-orphan-derived-data.sh --clear-shared-caches  # also clear ModuleCache and friends

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/derived-data.sh
source "${SCRIPT_DIR}/lib/derived-data.sh"

DRY_RUN="no"
CLEAR_SHARED="no"
# Deliberately a long way above empty. When the volume actually filled, the first symptom was `df`
# itself failing to run, so a warning that waits for a nearly full disk arrives after the ability to
# read it has already gone.
LOW_SPACE_GIB="${DERIVED_DATA_LOW_SPACE_GIB:-50}"

usage() {
  echo "Usage: scripts/reclaim-orphan-derived-data.sh [--dry-run] [--clear-shared-caches]" >&2
  exit 2
}

report_free_space() {
  local root="$1" available
  available="$(derived_data_available_gib "${root}")"
  if [[ -n "${available}" ]]; then
    echo "  ${available} GiB free."
  fi
  derived_data_space_warning "${available}" "${LOW_SPACE_GIB}" | sed 's/^/  /'
}

# The dead folders, one line each, with the workspace that no longer exists. Sizes are measured only
# here: `du` over a hundred folders is slow, and the default path runs before every push.
report_orphans() {
  local root="$1" dir size workspace
  while IFS= read -r dir; do
    [[ -n "${dir}" ]] || continue
    size="$(derived_data_size_mib "${dir}")"
    workspace="$(derived_data_workspace_path "${dir}")"
    echo "    $(basename "${dir}")  ${size:-unknown} MiB  workspace gone: ${workspace}"
  done < <(derived_data_orphans "${root}")
}

count_of() {
  printf '%s' "$1" | grep -c . || true
}

# Every folder under the root, classified, so the summary can say what was kept and why rather than
# only what went. A count with no breakdown cannot tell "nothing was dead" from "nothing was read".
classify_all() {
  local root="$1" dir
  for dir in "${root}"/*/; do
    dir="${dir%/}"
    [[ -d "${dir}" ]] || continue
    printf '%s\t%s\n' "$(derived_data_classify "${dir}")" "${dir}"
  done
}

clear_shared_caches() {
  local root="$1" verdict dir cleared=0
  while IFS=$'\t' read -r verdict dir; do
    [[ "${verdict}" == "shared-cache" ]] || continue
    if [[ "${DRY_RUN}" == "yes" ]]; then
      cleared=$((cleared + 1))
      continue
    fi
    if rm -rf "${dir}"; then
      cleared=$((cleared + 1))
    else
      echo "  could not remove ${dir}" >&2
    fi
  done < <(classify_all "${root}")

  if [[ "${DRY_RUN}" == "yes" ]]; then
    echo "  Would clear ${cleared} shared cache(s). Every project on this Mac then pays for one slow build."
  else
    echo "  Cleared ${cleared} shared cache(s). Every project on this Mac now pays for one slow build."
  fi
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)             DRY_RUN="yes"; shift ;;
      --clear-shared-caches) CLEAR_SHARED="yes"; shift ;;
      -h|--help)             usage ;;
      *)                     echo "Unknown argument: $1" >&2; usage ;;
    esac
  done

  local root
  root="$(derived_data_root)"

  if [[ ! -d "${root}" ]]; then
    # Not a clean sweep, and not silence either: finding nothing to look at is its own outcome (L98).
    echo "  There is no Xcode build output on this Mac to reclaim (nothing at ${root})."
    return 0
  fi

  local classified live_count unreadable_count shared_count
  classified="$(classify_all "${root}")"
  live_count="$(count_of "$(printf '%s\n' "${classified}" | grep '^live	' || true)")"
  unreadable_count="$(count_of "$(printf '%s\n' "${classified}" | grep '^unreadable	' || true)")"
  shared_count="$(count_of "$(printf '%s\n' "${classified}" | grep '^shared-cache	' || true)")"

  if [[ "${DRY_RUN}" == "yes" ]]; then
    local orphan_count
    orphan_count="$(count_of "$(derived_data_orphans "${root}")")"
    echo "  Would reclaim ${orphan_count} dead build folder(s):"
    report_orphans "${root}"
    echo "  This was a dry run, nothing was deleted."
  else
    # The number comes from the function that did the deleting, and it counts only the folders that
    # actually went. A folder it could not remove says so on stderr and is left out of the total, so
    # the line below reports what happened rather than what was attempted (L12).
    local reclaimed
    reclaimed="$(derived_data_reclaim "${root}")"
    echo "  Reclaimed ${reclaimed} dead build folder(s)."
  fi

  echo "  ${live_count} still in use, ${unreadable_count} unreadable and left alone, ${shared_count} shared cache(s)."

  if [[ "${CLEAR_SHARED}" == "yes" ]]; then
    clear_shared_caches "${root}"
  fi

  report_free_space "${root}"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
