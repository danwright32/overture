#!/usr/bin/env bash
set -uo pipefail

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

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "All run-debug.sh fixtures passed."
