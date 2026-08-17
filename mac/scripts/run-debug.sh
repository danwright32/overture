#!/usr/bin/env bash
set -euo pipefail

# Build and launch the Debug build (#567). Release has build-install.sh; Debug had nothing, so the
# only route was a raw xcodebuild followed by hunting the DerivedData path by hand to `open` the
# result.
#
# The friction this removes is not typing. During #488/#489's live verification a STALE Debug
# instance from an earlier build was still running and silently held the Debug store's
# single-writer lock, so a freshly launched instance came up in the degraded "another copy is using
# its data" state, and the change under test appeared not to work. This quits any existing Debug
# instance first, wherever it was built from.
#
# Safety, and the reason this script exists at all rather than a one-liner: Debug and Release keep
# SEPARATE stores (Overture-Debug vs the Application Support root) and separate bundle identities
# (com.danwright.overture.debug vs com.danwright.overture). A Debug build that somehow carried the
# RELEASE identity would open Dan's live store, which is the one outcome this must never allow. So
# the built bundle's identity is VERIFIED before it is launched, and the script refuses rather than
# guesses.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${MAC_DIR}/.." && pwd)"

# write_runner_defaults: points this build's preferences domain at THIS checkout's runner scripts
# (#2838). Shared with mac/build-install.sh, which does the same for the Release domain.
# shellcheck source=scripts/lib/runner-defaults.sh
source "${SCRIPT_DIR}/lib/runner-defaults.sh"

# shellcheck source=scripts/lib/stale-registrations.sh
source "${SCRIPT_DIR}/lib/stale-registrations.sh"
# shellcheck source=scripts/lib/app-quit.sh
source "${SCRIPT_DIR}/lib/app-quit.sh"

PROJECT="Overture.xcodeproj"
SCHEME="Overture"
CONFIG="Debug"
APP_NAME="Overture.app"
BUILD_DIR="${MAC_DIR}/build"
DEBUG_BUNDLE_ID="com.danwright.overture.debug"
RELEASE_BUNDLE_ID="com.danwright.overture"

# Every running Debug Overture, whatever it was built from. Deliberately BROADER than
# run-tests-locked.sh's stale_debug_test_host_pids, which matches only the DerivedData test host it
# spawned itself: a Debug app can also come from this script's own build/ directory, and any of them
# holds the same store lock. Kept as its own function rather than widening that one, because the two
# answer different questions. Making `xcodebuild test` kill a Debug app Dan launched by hand would be
# a worse bug than the one it fixes.
#
# The match is anchored on "/Build/Products/Debug/Overture.app/", which the RELEASE app
# (/Applications/Overture.app) can never contain. That is the load-bearing safety property here: this
# must never, under any circumstance, kill the resident app that holds the live store.
debug_app_pids() {
  local ps_output="$1"
  # `|| true`: a grep that matches nothing exits 1, and the caller runs under `set -euo pipefail`, so
  # that 1 would propagate out of the command substitution and kill the script before it built
  # anything. Finding no running Debug instance is the NORMAL case (a clean start with nothing stale
  # to quit), not an error, so it must be an empty answer with a zero status.
  echo "${ps_output}" \
    | grep -F "/Build/Products/${CONFIG}/${APP_NAME}/Contents/MacOS/Overture" \
    | awk '{print $1}' || true
}

# The identity the built bundle actually claims. A Debug bundle claiming the Release identity would
# open the LIVE store, so this is checked, never assumed.
built_bundle_id() {
  local app_path="$1"
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${app_path}/Contents/Info.plist" 2>/dev/null || true
}

# Refuse to launch anything that is not unmistakably the Debug identity. Returns non-zero with a
# reason, rather than launching something that could write to Dan's real prospects.
assert_is_debug_bundle() {
  local actual="$1"
  if [[ -z "${actual}" ]]; then
    echo "Refusing to launch: could not read the built app's bundle identifier." >&2
    return 1
  fi
  if [[ "${actual}" == "${RELEASE_BUNDLE_ID}" ]]; then
    echo "Refusing to launch: the built app claims the RELEASE identity (${actual})." >&2
    echo "It would open the live store instead of the isolated Debug one." >&2
    return 1
  fi
  if [[ "${actual}" != "${DEBUG_BUNDLE_ID}" ]]; then
    echo "Refusing to launch: unexpected bundle identifier ${actual} (expected ${DEBUG_BUNDLE_ID})." >&2
    return 1
  fi
  return 0
}

# #2072: the TERM, bounded wait, escalate, verify loop is the shared driver in lib/app-quit.sh
# now (build-install.sh needs the identical pattern for the Release bundle), with debug_app_pids
# above still deciding WHAT may be killed. The driver also verifies the process is actually gone,
# so a Debug instance that somehow survives kill -9 stops the run here with the survivor named,
# instead of proceeding into the launch that would come up degraded on the held store lock.
quit_running_debug_instances() {
  quit_matched_instances debug_app_pids "Debug instance(s)"
}

# #1970: drop the registration for the bundle path this build is about to replace.
#
# Every Xcode build registers the built app with LaunchServices and nothing ever unregisters it, so
# the count grew by one per build forever: 78 registrations for the Debug bundle by 2026-08-04, 76 of
# them pointing at deleted DerivedData folders. The bundle sets LSMultipleInstancesProhibited, so a
# launch asks LaunchServices to route to an existing instance, against those phantoms. Unregistering
# the path first keeps the count at one, and costs about 9ms.
#
# Best-effort on purpose: a missing or unhappy LaunchServices is not a reason to refuse to compile.
drop_previous_registration() {
  overture_unregister_path "${1:-}"
}

main() {
  cd "${MAC_DIR}"

  if command -v xcodegen >/dev/null; then
    echo "==> Regenerating ${PROJECT} (xcodegen)"
    xcodegen generate >/dev/null
  fi

  # Before the build, not after: a build can take a while, and the stale instance is holding the lock
  # the whole time.
  quit_running_debug_instances

  # #1970: and drop the outgoing bundle's registration before the build replaces it, so the Debug id
  # keeps ONE registration instead of collecting one per build.
  drop_previous_registration "${BUILD_DIR}/Build/Products/${CONFIG}/${APP_NAME}"

  echo "==> Building ${SCHEME} (${CONFIG})"
  xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIG}" \
    -derivedDataPath "${BUILD_DIR}" \
    -destination 'platform=macOS' \
    build \
    | (command -v xcbeautify >/dev/null && xcbeautify || cat)

  local built_app="${BUILD_DIR}/Build/Products/${CONFIG}/${APP_NAME}"
  if [[ ! -d "${built_app}" ]]; then
    echo "Error: build succeeded but ${built_app} not found" >&2
    exit 1
  fi

  local bundle_id
  bundle_id="$(built_bundle_id "${built_app}")"
  assert_is_debug_bundle "${bundle_id}" || exit 1

  # #2838: point the DEBUG defaults domain at THIS checkout's runner scripts.
  #
  # A Debug build reads `com.danwright.overture.debug`, a different preferences domain from the resident
  # Release app, so the three runner paths had to be set twice, by hand, from a runbook holding a literal
  # path. That is six entries recording where the checkout HAPPENED to be, none of them inside the repo
  # where anything could notice they had gone stale (L153). Written here because this script already
  # knows where the checkout is: it is running from inside it.
  #
  # Release's half is `mac/build-install.sh`, which writes the same three keys in the Release domain from
  # its own repo root, so neither has to be typed anywhere.
  write_runner_defaults "${DEBUG_BUNDLE_ID}" "${REPO_ROOT}"

  # DerivedData hashes change, so print what was ACTUALLY launched and which store it will touch.
  echo "==> Launching ${built_app}"
  echo "    bundle id: ${bundle_id}"
  echo "    store:     ~/Library/Application Support/Overture-Debug/"
  open "${built_app}"
}

# Sourceable without running main, so the pure helpers can be exercised directly. Mirrors
# run-tests-locked.sh's convention.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
