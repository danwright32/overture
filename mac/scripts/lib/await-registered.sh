#!/usr/bin/env bash
# #1160: `overture` (build-install.sh --launch) reliably launched TWO Overture instances. The login
# agent starts the resident copy; then `open overture://show` raced in before that copy had registered
# with LaunchServices, so LaunchServices launched a SECOND copy instead of delivering the URL to the
# first (LSMultipleInstancesProhibited, #1123, only routes to an ALREADY-registered instance). The
# second copy lost the store's single-writer lock and degraded.
#
# Wait for the resident copy to register with LaunchServices BEFORE surfacing the window, so
# `open overture://show` routes to it instead of spawning a duplicate. The in-app guard
# (StoreLaunchOutcome, #1160) is the belt-and-suspenders that terminates any duplicate that still slips
# through; this is the braces that stop one being spawned on the normal path.

# overture_await_bundle_registered BUNDLE_ID [MAX_ATTEMPTS]
#   Returns 0 as soon as BUNDLE_ID appears registered with LaunchServices, 1 if it never does within
#   MAX_ATTEMPTS probes (default 40 => ~10s at the default 0.25s sleep). Best-effort by design: the
#   caller surfaces the window regardless (the in-app duplicate guard covers a miss), so waiting only
#   ever IMPROVES the odds the URL routes to the resident.
#
#   The registration probe and the inter-probe sleep are injectable via $OVERTURE_LSREGISTERED_PROBE and
#   $OVERTURE_AWAIT_SLEEP so this is testable without LaunchServices or real elapsed time.
overture_await_bundle_registered() {
  local bundle_id="${1:-}" max_attempts="${2:-40}"
  local probe="${OVERTURE_LSREGISTERED_PROBE:-_overture_lsappinfo_registered}"
  local sleeper="${OVERTURE_AWAIT_SLEEP:-_overture_await_default_sleep}"
  [[ -n "${bundle_id}" ]] || return 1

  local attempt=0
  while (( attempt < max_attempts )); do
    if "${probe}" "${bundle_id}"; then
      return 0
    fi
    "${sleeper}"
    attempt=$(( attempt + 1 ))
  done
  return 1
}

# Default probe: LaunchServices' lsappinfo reports an ASN for a registered bundle id and nothing for an
# unregistered one. If lsappinfo isn't available we can't probe, so report registered rather than block
# the launch (the in-app duplicate guard still covers the resulting race). Overridable in tests.
_overture_lsappinfo_registered() {
  local bundle_id="${1:-}"
  command -v lsappinfo >/dev/null 2>&1 || return 0
  local asn
  asn="$(lsappinfo find "bundleid=${bundle_id}" 2>/dev/null)"
  [[ -n "${asn}" ]]
}

_overture_await_default_sleep() { sleep 0.25; }
