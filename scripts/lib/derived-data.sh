#!/usr/bin/env bash
# Decisions about which Xcode build folders can never be used again (#2585).
#
# Why this exists. Xcode keys ~/Library/Developer/Xcode/DerivedData by the workspace's PATH, so every
# git worktree that is ever built mints a fresh folder of roughly 1.6 GB, and nothing reclaims it when
# the worktree goes away. This repo's own tooling creates those paths constantly: every parallel agent
# gets a worktree, and scripts/verify-and-merge-branch.sh makes a throwaway one per verification. The
# growth is therefore proportional to how much the repo's workflow is used, and its ceiling is the disk.
#
# Measured on this Mac 2026-08-12: DerivedData held 148 GB in 105 Overture folders, 101 of which pointed
# at directories that had already been deleted. The volume was down to 132 MiB free on 926 GiB, every
# shell command failed, and `df` itself could not run because the harness could not write the command's
# own output file. Removing only the 101 dead ones took it to 152 GB free and touched nothing live.
#
# Every other toolchain in these repos caches INSIDE the project directory (node_modules, .next, venv,
# __pycache__), so deleting a worktree reclaims all of it for free. Xcode is the exception, and that is
# exactly where the leak is.
#
# The safety property everything here rests on: a folder whose WorkspacePath NO LONGER EXISTS can never
# be reused by anything, so deleting it costs nobody a rebuild. That is a far safer question than "how
# old is too old", and on 2026-08-12 it accounted for all 101. Every other answer, including every
# answer this file cannot work out, keeps the folder.
#
# The DerivedData root is a parameter everywhere and defaults through derived_data_root, so a fixture
# drives the real functions against a throwaway directory and can never reach the real one (L2).

# Where Xcode keeps its build output. Overridable so tests and callers can name their own.
derived_data_root() {
  printf '%s' "${XCODE_DERIVED_DATA_ROOT:-${HOME}/Library/Developer/Xcode/DerivedData}"
}

# The workspace one build folder belongs to, or an empty string when that cannot be read.
#
# Empty is deliberately the answer for every failure (no plist, no such key, no reader on this Mac),
# because the caller treats an unreadable answer as a reason to KEEP. A reader that guessed would be
# guessing about a 1.6 GB folder somebody may still be building against.
derived_data_workspace_path() {
  local dir="${1:-}"
  local plist="${dir}/info.plist"
  [[ -n "${dir}" && -r "${plist}" ]] || return 0

  local path=""
  if [[ -x /usr/libexec/PlistBuddy ]]; then
    path="$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "${plist}" 2>/dev/null)" || path=""
  fi
  # plutil is the fallback rather than the first choice only because PlistBuddy is the one measured
  # against real Xcode output on 2026-08-12. Both read the binary and XML forms.
  if [[ -z "${path}" ]] && command -v plutil >/dev/null 2>&1; then
    path="$(plutil -extract WorkspacePath raw -o - "${plist}" 2>/dev/null)" || path=""
  fi
  printf '%s' "${path}"
}

# False when the path names a volume that is not currently mounted.
#
# This is the one way the orphan rule could fail open. An unplugged external drive makes every
# workspace on it look deleted, and the folders would then be reclaimed while the work they belong to
# is perfectly fine and about to be plugged back in.
derived_data_volume_is_available() {
  local path="${1:-}" volume
  case "${path}" in
    /Volumes/*)
      volume="/Volumes/$(printf '%s' "${path#/Volumes/}" | cut -d/ -f1)"
      [[ -d "${volume}" ]] || return 1
      ;;
  esac
  return 0
}

# One of: shared-cache, unreadable, live, orphan. Only "orphan" is ever deleted.
#
#   shared-cache  ModuleCache.noindex and friends. Not keyed by a workspace at all, so the orphan rule
#                 cannot speak about them, and they are shared by every project on the Mac: clearing
#                 them is safe but NOT free, since the next build of everything pays for it once.
#                 They were another 44 GB when measured, and they get their own louder prompt.
#   unreadable    Anything this file could not settle. Kept.
#   live          The workspace is still on disk. Kept.
#   orphan        The workspace is gone. Nothing can ever use this folder again.
derived_data_classify() {
  local dir="${1:-}"
  [[ -n "${dir}" && -d "${dir}" ]] || { printf 'unreadable'; return 0; }

  case "$(basename "${dir}")" in
    *.noindex) printf 'shared-cache'; return 0 ;;
  esac

  local workspace
  workspace="$(derived_data_workspace_path "${dir}")"
  # A relative path is refused rather than resolved: it would be resolved against whatever directory
  # the caller happened to be in, and a wrong answer here deletes something.
  if [[ -z "${workspace}" || "${workspace}" != /* ]]; then
    printf 'unreadable'
    return 0
  fi
  if ! derived_data_volume_is_available "${workspace}"; then
    printf 'unreadable'
    return 0
  fi
  if [[ -e "${workspace}" ]]; then
    printf 'live'
  else
    printf 'orphan'
  fi
  return 0
}

# Every folder under ROOT that is provably dead, one path per line.
derived_data_orphans() {
  local root="${1:-$(derived_data_root)}"
  [[ -d "${root}" ]] || return 0

  local dir
  for dir in "${root}"/*/; do
    dir="${dir%/}"
    [[ -d "${dir}" ]] || continue
    if [[ "$(derived_data_classify "${dir}")" == "orphan" ]]; then
      printf '%s\n' "${dir}"
    fi
  done
  return 0
}

# Deletes every orphan under ROOT and prints how many went. A folder that cannot be removed is named
# on stderr and NOT counted, so the number reported is what actually happened rather than what was
# attempted (L12).
derived_data_reclaim() {
  local root="${1:-$(derived_data_root)}"
  local removed=0 dir
  while IFS= read -r dir; do
    [[ -n "${dir}" ]] || continue
    if rm -rf "${dir}"; then
      removed=$((removed + 1))
    else
      echo "derived-data: could not remove ${dir}" >&2
    fi
  done < <(derived_data_orphans "${root}")
  printf '%s\n' "${removed}"
  return 0
}

# Every build folder whose workspace lives inside WORKSPACE_DIR, one path per line.
#
# Used by the verify script to remove the folder it caused at the moment it removes the worktree,
# rather than leaving it for a later sweep. Matching is on a full path COMPONENT, never a bare string
# prefix: two throwaway worktrees from mktemp routinely share a prefix (overture-verify-2585.abcdef
# and overture-verify-2585.abcdefGHI), and a prefix test would delete another run's live folder.
derived_data_for_workspace() {
  local root="${1:-}" workspace_dir="${2:-}"
  [[ -n "${workspace_dir}" && -d "${root}" ]] || return 0
  workspace_dir="${workspace_dir%/}"

  local dir path
  for dir in "${root}"/*/; do
    dir="${dir%/}"
    [[ -d "${dir}" ]] || continue
    path="$(derived_data_workspace_path "${dir}")"
    [[ -n "${path}" ]] || continue
    if [[ "${path}" == "${workspace_dir}/"* ]]; then
      printf '%s\n' "${dir}"
    fi
  done
  return 0
}

# Deletes the build folders belonging to one workspace directory and prints how many went. Safe to
# call after the directory itself is gone, which is the order the caller uses.
derived_data_reclaim_for_workspace() {
  local root="${1:-}" workspace_dir="${2:-}"
  local removed=0 dir
  while IFS= read -r dir; do
    [[ -n "${dir}" ]] || continue
    if rm -rf "${dir}"; then
      removed=$((removed + 1))
    else
      echo "derived-data: could not remove ${dir}" >&2
    fi
  done < <(derived_data_for_workspace "${root}" "${workspace_dir}")
  printf '%s\n' "${removed}"
  return 0
}

# The warning to print when free space is getting low, or nothing at all when it is fine.
#
# Both figures are whole GiB. The threshold has to fire a long way before the disk is full: when it
# filled on 2026-08-12 the first symptom was not a build failure, it was `df` failing to run, so by the
# time the condition is visible it has already removed the ability to look at it.
#
# An unreadable figure is reported rather than scored. A blank or non-numeric value compares false
# against every threshold, which would silently land on the healthy side and make the check report
# most confidently exactly when it measured nothing (L50).
derived_data_space_warning() {
  local available_gib="${1:-}" threshold_gib="${2:-}"

  if [[ ! "${available_gib}" =~ ^[0-9]+$ || ! "${threshold_gib}" =~ ^[0-9]+$ ]]; then
    echo "Disk space check: could not read how much space is free, so this run cannot say whether it is low."
    return 0
  fi

  if [[ "${available_gib}" -ge "${threshold_gib}" ]]; then
    return 0
  fi

  echo "Disk space is low: ${available_gib} GiB free, below the ${threshold_gib} GiB mark."
  echo "  Xcode build output is the usual cause here. Run scripts/reclaim-orphan-derived-data.sh to clear what is dead,"
  echo "  and add --clear-shared-caches if that is not enough (that one costs every project one slow build)."
  return 0
}

# Whole GiB free on the volume holding PATH, or an empty string when df could not answer. Empty rather
# than a fallback number, so the caller reports "could not read" instead of a figure nobody measured.
derived_data_available_gib() {
  local path="${1:-${HOME}}"
  local kib
  kib="$(df -k "${path}" 2>/dev/null | awk 'NR==2 {print $4}')" || kib=""
  [[ "${kib}" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$((kib / 1024 / 1024))"
}

# Size of a directory in whole MiB, or an empty string when it cannot be read.
derived_data_size_mib() {
  local path="${1:-}"
  local kib
  [[ -d "${path}" ]] || return 0
  kib="$(du -sk "${path}" 2>/dev/null | awk '{print $1}')" || kib=""
  [[ "${kib}" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$((kib / 1024))"
}
