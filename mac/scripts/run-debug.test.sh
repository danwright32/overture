#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/shell-assertions.sh"

# Coverage for run-debug.sh's pure helpers (#567). The two things worth proving here are both
# SAFETY properties, not conveniences:
#
#   1. The process finder must never match the Release app. It kills what it finds, and the Release
#      app is the one holding Dan's live store.
#   2. The bundle-identity guard must refuse anything that is not unmistakably the Debug identity. A
#      Debug launch that somehow carried the Release identity would open the live store.
#
# Real-shaped `ps -eo pid=,command=` fixtures rather than a live process table, since this is a pure
# text match over already-produced output (mirrors run-tests-locked.test.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./run-debug.sh
source "${SCRIPT_DIR}/run-debug.sh"
set +e

FAILURES=0

assert_equals() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_succeeds() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc} (expected success, got failure)"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_fails() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL - ${desc} (expected failure, got success)"
    FAILURES=$((FAILURES + 1))
  else
    echo "ok - ${desc}"
  fi
}

# --- debug_app_pids ---

# A Debug app built by THIS script (build/) and one built by Xcode (DerivedData) are both Debug
# instances holding the same store lock, and both must be found.
PS_BOTH_DEBUG_BUILDS="$(cat <<'EOF'
  501 /Users/dan/repo/mac/build/Build/Products/Debug/Overture.app/Contents/MacOS/Overture
  777 /Users/dan/Library/Developer/Xcode/DerivedData/Overture-abc/Build/Products/Debug/Overture.app/Contents/MacOS/Overture
EOF
)"
assert_equals "finds a Debug app built into build/ and one from DerivedData" \
  "$(printf '501\n777')" \
  "$(debug_app_pids "${PS_BOTH_DEBUG_BUILDS}")"

# THE safety test. The Release app at /Applications holds the LIVE store. Matching it here would
# mean this script kills the real app, and worse, implies a path confusion that could end with a
# Debug run pointed at live data.
PS_WITH_RELEASE="$(cat <<'EOF'
  100 /Applications/Overture.app/Contents/MacOS/Overture
  200 /Users/dan/repo/mac/build/Build/Products/Release/Overture.app/Contents/MacOS/Overture
  300 /Users/dan/repo/mac/build/Build/Products/Debug/Overture.app/Contents/MacOS/Overture
EOF
)"
assert_equals "never matches the Release app, in /Applications or in a Release build dir" \
  "300" \
  "$(debug_app_pids "${PS_WITH_RELEASE}")"

assert_equals "no Debug instance running yields nothing (the normal first-launch case)" \
  "" \
  "$(debug_app_pids "  100 /Applications/Overture.app/Contents/MacOS/Overture")"

# ...and it must EXIT ZERO while doing so. This is not pedantry: the helper ends in `grep | awk`, and
# a grep that matches nothing exits 1. Its caller (quit_running_debug_instances) runs under
# `set -euo pipefail`, so that 1 propagates out of the command substitution and kills the whole script
# BEFORE it builds anything.
#
# Which means the one tool whose entire job is "let me actually look at the app" was broken in the
# COMMON case: a clean start, with no stale instance to quit. It only worked when a stale Debug
# instance happened to be lying around, which is the case it exists to clean up. Found while trying to
# look at the #799 Add-a-lead sheet.
#
# The assertion above passes even when this is broken, because this file relaxes `set -e` after
# sourcing. The exit status is the thing that has to be pinned.
debug_app_pids "  100 /Applications/Overture.app/Contents/MacOS/Overture" >/dev/null
assert_equals "finding nothing exits 0, so a caller under 'set -e' survives a clean start" \
  "0" "$?"

# An unrelated process that merely mentions Overture must not be killed.
assert_equals "ignores an unrelated process that only mentions the app by name" \
  "" \
  "$(debug_app_pids "  900 /usr/bin/tail -f /Users/dan/Library/Logs/Overture/stdout.log")"

# --- assert_is_debug_bundle ---

assert_succeeds "accepts the Debug identity" \
  assert_is_debug_bundle "com.danwright.overture.debug"

# The one outcome this whole script exists to prevent: a bundle claiming the RELEASE identity would
# open the live store, so it must be refused rather than launched.
assert_fails "REFUSES the Release identity (it would open the live store)" \
  assert_is_debug_bundle "com.danwright.overture"

assert_fails "refuses an unreadable/absent identity rather than guessing" \
  assert_is_debug_bundle ""

assert_fails "refuses an unexpected identity" \
  assert_is_debug_bundle "com.someone.else"

# --- drop_previous_registration (#1970) ---
#
# Every Xcode build registers the built app with LaunchServices and nothing ever unregisters it:
# measured on this Mac 2026-08-04, com.danwright.overture.debug had 78 registrations, 76 of them
# pointing at deleted DerivedData folders and retired worktrees. The bundle is single-instance, so
# launching it asks LaunchServices to route to an existing instance against that pile of phantoms.
# This script is the one that rebuilds the Debug bundle, so it is where the count is kept at one.
LSTMP="$(fixture_scratch_dir)"
trap 'rm -rf "${LSTMP}"' EXIT
LSLOG="${LSTMP}/asked"
cat >"${LSTMP}/lsregister" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "\$1" "\$2" >> "${LSLOG}"
EOF
chmod +x "${LSTMP}/lsregister"

: > "${LSLOG}"
LSREGISTER="${LSTMP}/lsregister" drop_previous_registration "/some path/build/Build/Products/Debug/Overture.app"
assert_equals "unregisters the exact bundle path the build is about to replace" \
  "-u /some path/build/Build/Products/Debug/Overture.app" \
  "$(cat "${LSLOG}")"

# The failure path, and it matters more than the happy one: this is a convenience running before a
# build, so a LaunchServices that is missing or unhappy must not stop Dan compiling.
with_missing_registrar() {
  LSREGISTER="${LSTMP}/not-installed" drop_previous_registration "/some path/Overture.app"
}
: > "${LSLOG}"
assert_succeeds "a missing registrar does not take the build down" with_missing_registrar
assert_equals "and asks nothing of it" "" "$(cat "${LSLOG}")"

# --- resolve_store_folder (#4338) ---
#
# The store folder option exists so a SYNTHETIC store can be looked at. Its whole value is the two
# refusals: the live Release folder holds Dan's real data, and the default Debug folder is the one his
# ordinary Debug runs keep. Each is refused named directly, from inside, from above, and through a link.
SFTMP="$(fixture_scratch_dir)"
trap 'rm -rf "${LSTMP}" "${SFTMP}"' EXIT
APPSUP="${SFTMP}/Application Support"
mkdir -p "${APPSUP}/Overture/inner" "${APPSUP}/Overture-Debug/inner" "${SFTMP}/scratch store"
ln -s "${APPSUP}/Overture" "${SFTMP}/link-to-live"
SCRATCH_REAL="$(cd "${SFTMP}/scratch store" && pwd -P)"

assert_equals "a named scratch folder is accepted and printed as resolved" \
  "${SCRATCH_REAL}" "$(resolve_store_folder "${SFTMP}/scratch store" "${APPSUP}" 2>/dev/null)"
assert_fails "REFUSES the live Release folder" resolve_store_folder "${APPSUP}/Overture" "${APPSUP}"
assert_fails "REFUSES the default Debug folder" resolve_store_folder "${APPSUP}/Overture-Debug" "${APPSUP}"
assert_fails "refuses a folder inside the live one" resolve_store_folder "${APPSUP}/Overture/inner" "${APPSUP}"
assert_fails "refuses a folder inside the Debug one" resolve_store_folder "${APPSUP}/Overture-Debug/inner" "${APPSUP}"
assert_fails "refuses Application Support itself, which holds both" resolve_store_folder "${APPSUP}" "${APPSUP}"
assert_fails "refuses a link that points at the live folder" resolve_store_folder "${SFTMP}/link-to-live" "${APPSUP}"
assert_fails "refuses a folder that does not exist" resolve_store_folder "${SFTMP}/not-made" "${APPSUP}"
assert_fails "refuses no folder at all" resolve_store_folder "" "${APPSUP}"
# The refusal says which folder and why, so a person reading it knows what to change.
assert_contains "the live refusal names the folder it refused" \
  "$(resolve_store_folder "${APPSUP}/Overture" "${APPSUP}" 2>&1)" "${APPSUP}/Overture"

# The startup volume ignores letter case, so a path spelled in other letters names the same folder, and
# `pwd -P` keeps the letters it was given. Each spelling below was accepted by a comparison of path text;
# the refusal compares the folders themselves, by device and inode. The first line checks the premise: on a
# volume that respects case these spellings name nothing, and every refusal below would pass for that reason.
CASED="${SFTMP}/application support"
assert_succeeds "the scratch volume ignores case, so the spellings below name the real folders" \
  test -d "${CASED}/overture/inner"
assert_fails "REFUSES the live folder spelled in other letters" resolve_store_folder "${CASED}/overture" "${APPSUP}"
assert_fails "REFUSES a folder inside the live one spelled in other letters" \
  resolve_store_folder "${CASED}/OVERTURE/inner" "${APPSUP}"
assert_fails "REFUSES the Debug folder spelled in other letters" \
  resolve_store_folder "${CASED}/overture-debug" "${APPSUP}"
assert_fails "refuses Application Support spelled in other letters" resolve_store_folder "${CASED}" "${APPSUP}"
assert_fails "refuses the live folder when Application Support itself arrives in other letters" \
  resolve_store_folder "${APPSUP}/Overture" "${CASED}"
assert_fails "refuses the top of the disk, which holds everything" resolve_store_folder "/" "${APPSUP}"
# Before the live folder exists, the folder that would hold it is still refused, and a scratch folder is not.
EMPTYSUP="${SFTMP}/Empty Support"
mkdir -p "${EMPTYSUP}"
assert_fails "refuses the folder that would hold the live one before it exists" \
  resolve_store_folder "${EMPTYSUP}" "${EMPTYSUP}"
assert_fails "and refuses it however Application Support is spelled" \
  resolve_store_folder "${EMPTYSUP}" "${SFTMP}/empty support"
assert_equals "while a scratch folder beside it is still accepted" \
  "${SCRATCH_REAL}" "$(resolve_store_folder "${SFTMP}/scratch store" "${EMPTYSUP}" 2>/dev/null)"

# --- launch_arguments (#4338) ---
assert_equals "no folder hands the app nothing" "" "$(launch_arguments "")"
assert_equals "a store folder is handed to the app under its own flag" \
  "$(printf '%s\n%s' "--overture-store-folder" "/tmp/x y")" "$(launch_arguments "/tmp/x y")"

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "All run-debug.sh fixtures passed."
