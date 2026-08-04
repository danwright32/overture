#!/usr/bin/env bash
set -euo pipefail

# #1970: clear LaunchServices registrations for Overture that point at bundles which no longer exist,
# and report when they are piling up again.
#
# Every Xcode build registers the built app and nothing ever unregisters it, so the count grew by one
# per build forever. Measured on this Mac 2026-08-04: 78 registrations for com.danwright.overture.debug,
# 76 of them pointing at deleted DerivedData folders and retired agent worktrees, plus 12 for the
# Release id. The bundle sets LSMultipleInstancesProhibited, so launching it asks LaunchServices to
# route to an existing instance, against that pile of phantoms.
#
# run-debug.sh now drops the outgoing bundle's registration before each build, which stops the Debug
# path from multiplying. This clears what is already there and whatever prevention cannot cover (a
# test host in a DerivedData folder that is later cleaned, a worktree that is retired).
#
# Usage:
#   prune-stale-registrations.sh            remove every stale registration, and say how many
#   prune-stale-registrations.sh --check    count them and warn past the threshold, changing nothing
#
# Only ever unregisters a path that is GONE from disk (overture_stale_registrations owns that rule),
# so it can never unregister a bundle that is actually installed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/stale-registrations.sh
source "${SCRIPT_DIR}/lib/stale-registrations.sh"

BUNDLE_IDS=("com.danwright.overture" "com.danwright.overture.debug")
DUMP_FILE=""
WARN_ABOVE="${OVERTURE_STALE_REGISTRATION_THRESHOLD:-10}"
LSREGISTER_BIN="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister}"

main() {
  local mode="${1:-prune}"

  if [ ! -x "${LSREGISTER_BIN}" ]; then
    # Fail loud rather than reporting a clean database that was never read (L11).
    echo "prune-stale-registrations: cannot read LaunchServices (no lsregister at ${LSREGISTER_BIN})." >&2
    return 0
  fi

  # Global, not local: the trap below runs after main has returned, and a local would be gone by then
  # (unbound under `set -u`, which is a failing script reporting nothing about what it removed).
  DUMP_FILE="$(mktemp)"
  local dump="${DUMP_FILE}"
  trap 'rm -f "${DUMP_FILE:-}"' EXIT
  "${LSREGISTER_BIN}" -dump > "${dump}" 2>/dev/null || true

  local total_stale=0 id stale count
  for id in "${BUNDLE_IDS[@]}"; do
    stale="$(overture_stale_registrations "${dump}" "${id}")"
    count="$(printf '%s' "${stale}" | grep -c . || true)"
    total_stale=$((total_stale + count))
    if [ "${mode}" = "--check" ]; then
      echo "  ${id}: ${count} stale registration(s)"
      continue
    fi
    local removed
    removed="$(overture_unregister_stale "${dump}" "${id}")"
    echo "  ${id}: removed ${removed} stale registration(s)"
  done

  if [ "${mode}" = "--check" ]; then
    local warning
    warning="$(overture_registration_warning "${total_stale}" "${WARN_ABOVE}")"
    [ -n "${warning}" ] && echo "${warning}"
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
