#!/usr/bin/env bash
# #1970: LaunchServices registrations for Overture that point at bundles which no longer exist.
#
# Every Xcode build registers the built app, and nothing ever unregisters it. Measured on this Mac
# 2026-08-04: com.danwright.overture.debug had 78 registrations, 76 of them pointing at deleted
# DerivedData folders and retired agent worktrees. That matters more than untidiness, because the
# bundle sets LSMultipleInstancesProhibited: launching it asks LaunchServices to route to an existing
# instance, and it was doing that against a pile of phantoms.
#
# Also measured that day, and contrary to what #1970 recorded: `lsregister -u <path>` costs about 9ms
# per entry, live or dead. So the pile can be cleared, and needs neither the database deleted nor the
# Mac rebooted. Prevention (unregistering the path a build is about to replace) plus this cleanup is
# the whole fix.
#
# The registrar is overridable via $LSREGISTER so every one of these stays testable without touching
# the real LaunchServices database (L2).

# The dump's own shape, read from real output on 2026-08-04: records are separated by a line of
# dashes, the `path:` line carries a trailing "(0x....)" token, and the `identifier:` line comes
# after the path inside the same record.
#
# overture_registered_paths DUMP_FILE BUNDLE_ID
#   Prints every path LaunchServices has registered under BUNDLE_ID, one per line, in dump order.
overture_registered_paths() {
  local dump="${1:-}" bundle_id="${2:-}"
  [ -r "${dump}" ] || return 0
  [ -n "${bundle_id}" ] || return 0
  awk -v want="${bundle_id}" '
    /^-----/ { path = ""; next }
    /^path:[[:space:]]/ {
      path = $0
      sub(/^path:[[:space:]]+/, "", path)
      sub(/[[:space:]]+\(0x[0-9a-fA-F]+\)$/, "", path)
      next
    }
    /^identifier:[[:space:]]/ {
      id = $0
      sub(/^identifier:[[:space:]]+/, "", id)
      if (id == want && path != "") { print path }
      next
    }
  ' "${dump}"
}

# overture_stale_registrations DUMP_FILE BUNDLE_ID
#   Prints only those registered paths that are GONE from disk. This is the safety property the whole
#   cleanup rests on: a bundle still on disk is never stale, whatever else is true of it, so nothing
#   here can unregister a live app.
overture_stale_registrations() {
  local dump="${1:-}" bundle_id="${2:-}" path
  overture_registered_paths "${dump}" "${bundle_id}" | while IFS= read -r path; do
    [ -n "${path}" ] || continue
    [ -e "${path}" ] || printf '%s\n' "${path}"
  done
}

# overture_unregister_stale DUMP_FILE BUNDLE_ID
#   Unregisters every stale path and prints how many were removed. Never fails: this runs as a
#   convenience beside a build, and a missing or unhappy LaunchServices is not a reason to refuse to
#   compile. A path that is still on disk is never handed to the registrar.
overture_unregister_stale() {
  local dump="${1:-}" bundle_id="${2:-}"
  local lsregister="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister}"
  local removed=0 path stale
  if [ ! -x "${lsregister}" ]; then
    echo 0
    return 0
  fi
  stale="$(overture_stale_registrations "${dump}" "${bundle_id}")"
  while IFS= read -r path; do
    [ -n "${path}" ] || continue
    "${lsregister}" -u "${path}" >/dev/null 2>&1 || true
    removed=$((removed + 1))
  done <<EOF
${stale}
EOF
  echo "${removed}"
  return 0
}

# overture_unregister_path PATH
#   Drops one bundle path's registration, whether or not it still exists. Called by run-debug.sh for
#   the path it is ABOUT to replace, which is what keeps the count at one instead of one per build.
#   Best-effort by the same reasoning as above.
overture_unregister_path() {
  local path="${1:-}"
  local lsregister="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister}"
  [ -n "${path}" ] || return 0
  [ -x "${lsregister}" ] || return 0
  "${lsregister}" -u "${path}" >/dev/null 2>&1 || true
  return 0
}
