#!/usr/bin/env bash
# 2026-07-18: `overture` (build-install.sh --launch) left a second Release Overture.app in the build
# products. That stray copy carries the same com.danwright.overture bundle id and overture:// URL
# scheme as the installed /Applications copy, so `open overture://show` (the launch surface) could
# route to the STRAY build copy and launch a second instance, which the store's single-writer lock
# then refused with the "Overture's data is unavailable" screen (the two-copies clash).
#
# Debug builds are immune by construction: they carry com.danwright.overture.debug and the
# overture-debug:// scheme (#568), so only a stray RELEASE bundle can shadow the installed one, and
# build-install.sh only ever produces one, in its own build products.
#
# After the install copies the bundle to /Applications, call this to remove the just-built copy and
# re-register the installed bundle as the canonical overture:// handler, so the launch surface can
# only ever resolve to /Applications.

# overture_dedupe_installed_bundle BUILT_APP DEST
#   BUILT_APP: the freshly built .app in the build products (removed if present).
#   DEST:      the installed .app in /Applications (re-registered with LaunchServices).
#
# Idempotent: a missing BUILT_APP or DEST is a no-op, never an error. It NEVER deletes BUILT_APP when
# it is the same path as DEST (that would wipe the live installed app). The LaunchServices registrar
# is overridable via $LSREGISTER so this stays testable without touching the real database.
overture_dedupe_installed_bundle() {
  local built_app="${1:-}" dest="${2:-}"
  local lsregister="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"

  # Remove the stray build copy, but never the installed bundle itself.
  if [[ -n "${built_app}" && "${built_app}" != "${dest}" && -e "${built_app}" ]]; then
    rm -rf "${built_app}"
  fi

  # Make the installed bundle the current overture:// handler. Best-effort: a missing or unusable
  # registrar must not fail the install.
  if [[ -n "${dest}" && -e "${dest}" && -x "${lsregister}" ]]; then
    "${lsregister}" -f "${dest}" >/dev/null 2>&1 || true
  fi
}
