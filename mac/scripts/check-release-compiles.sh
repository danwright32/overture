#!/usr/bin/env bash
set -uo pipefail

# Does the RELEASE configuration of the app compile? (the Update button failure, 2026-09-24)
#
# WHY THIS EXISTS. Every build anything here runs before a merge is a Debug build: the Mac suite, the
# `swift-tests` CI job, and the verify-and-merge scripts all build the Debug configuration, because
# that is what `xcodebuild test` builds. The only thing that ever built Release was the Update button
# (`mac/build-install.sh`), AFTER the change had shipped. So code that compiles only in Debug merged
# green and broke the install: #4204 called `QueueRenderCounter`, which is declared inside `#if DEBUG`,
# from two places in SourcesView.swift with no guard around them, and on 2026-09-24 Update failed with
# "cannot find 'QueueRenderCounter' in scope" on a main every check called healthy.
#
# The class is "a symbol that exists in one configuration only", and a source scan for it would be a
# hand-kept list of which symbols are Debug-only (L96). Compiling Release is the only check that knows
# the whole list, because it is the compiler's own.
#
# WHAT IT BUILDS. The same scheme and configuration the installer builds, with two settings overridden
# so the product is never a stand-in for the real app: its own bundle identifier and its own URL scheme.
# A second bundle claiming the Release identity is what once shadowed /Applications and launched a
# duplicate the store lock refused (see mac/build-install.sh). One architecture only, since the question
# is whether the code compiles, and conditional compilation is identical across the two.
#
# Exit 0: it compiled. Exit 1: it did not, and the compiler's errors are printed. Exit 2: nothing was
# measured (no xcodebuild, no flock), which must never read as a pass (L98).
#
# Usage: mac/scripts/check-release-compiles.sh
# Seams: OVERTURE_FILE_LOCK and OVERTURE_DIR_LOCK (the two locks, read exactly as run-tests-locked.sh
# reads them, because they ARE its locks), LSREGISTER (the registrar, as stale-registrations.sh reads it)
# and OVERTURE_RELEASE_CHECK_DERIVED_DATA (where the build goes; kept between runs so a rerun is
# incremental).

# BOTH of the Mac suite's locks, taken by the suite's own functions rather than a copy of them: the
# flock that serialises Overture's own xcodebuild runs, and the directory lock Downbeat takes, so a
# Downbeat test run can never overlap this build. Sourcing the runner defines them without running it.
# shellcheck source=./run-tests-locked.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-tests-locked.sh"
# shellcheck source=./lib/stale-registrations.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/stale-registrations.sh"
set +e
DERIVED_DATA="${OVERTURE_RELEASE_CHECK_DERIVED_DATA:-${HOME}/Library/Caches/overture-release-compile-check}"
CHECK_BUNDLE_ID="com.danwright.overture.releasecheck"
CHECK_URL_SCHEME="overture-releasecheck"

for tool in xcodebuild flock; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "check-release-compiles.sh: UNMEASURED, ${tool} is not on PATH, so the Release build was never attempted." >&2
    exit 2
  fi
done

# The built app is removed however this ends. Only the product goes: the intermediates stay, which is
# what makes the next run incremental rather than a cold build. It is UNREGISTERED first: xcodebuild
# registers every app it builds with LaunchServices, and deleting the bundle alone leaves a registration
# pointing at nothing, one per run. prune-stale-registrations.sh only knows the two real identities, so
# nothing else would ever clear these (#1970 measured 78 of that shape for the Debug build).
remove_product() {
  overture_unregister_path "${DERIVED_DATA}/Build/Products/Release/Overture.app"
  rm -rf "${DERIVED_DATA}/Build/Products" 2>/dev/null || true
}
# Cleanup on EXIT only, and an interrupt EXITS (L473, downbeat#524): a trap on INT or TERM that only
# cleaned up let this carry on round the lock wait, rejoining the queue at the back, or go on building
# after it had released the lock. `exit` runs the EXIT trap, so the cleanup still happens once.
trap 'remove_product; release_dir_lock; rm -f "${BUILD_LOG:-}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/overture-release-check.XXXXXX")"

echo "==> Compiling the Release configuration (the one the Update button installs)"
cd "${MAC_DIR}" || exit 2
take_dir_lock
build_status=0
flock "${LOCK_FILE}" xcodebuild \
  -project Overture.xcodeproj \
  -scheme Overture \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA}" \
  -destination 'platform=macOS' \
  ONLY_ACTIVE_ARCH=YES \
  PRODUCT_BUNDLE_IDENTIFIER="${CHECK_BUNDLE_ID}" \
  OVERTURE_URL_SCHEME="${CHECK_URL_SCHEME}" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build >"${BUILD_LOG}" 2>&1 || build_status=$?

if [[ "${build_status}" -eq 0 ]]; then
  echo "Release compiles."
  exit 0
fi

echo "FAILED - the Release configuration does not compile (xcodebuild exit ${build_status})." >&2
echo "The Update button builds exactly this, so it would fail the same way. The compiler said:" >&2
# Each error once: xcodebuild repeats every diagnostic per architecture and again in its summary.
errors="$(grep -E '^/.*: error: ' "${BUILD_LOG}" | sort -u || true)"
if [[ -n "${errors}" ]]; then
  echo "${errors}" >&2
  echo "A symbol that exists only in Debug (declared inside #if DEBUG) must be used inside #if DEBUG too." >&2
else
  # No compiler error to show means it failed somewhere else, so the tail is the evidence.
  tail -n 40 "${BUILD_LOG}" >&2
fi
exit 1
