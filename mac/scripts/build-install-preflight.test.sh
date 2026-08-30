#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/shell-assertions.sh"

# #1526: build-install.sh must prove codesign will accept the stable signing identity BEFORE it
# builds anything, not after it has replaced /Applications/Overture.app.
#
# On 2026-07-26 the identity was listed but codesign refused it, so a full Release build ran, the
# working installed copy was deleted and replaced, and only THEN did signing fail. The build was
# wasted and the app Dan had was gone. The check existing in stable-signing.sh is one claim; this
# pins the other one, that build-install.sh actually runs it, and runs it first (L3).
#
# SAFETY: this drives a COPY of build-install.sh in a throwaway directory, never the real one in
# place. In the exact state this fixture exists to catch (no pre-flight at all) the script carries
# straight on to xcodebuild and then to /Applications. A copy's build directory lives inside the
# throwaway, so the script's own "build succeeded but the app is not there" guard stops it long
# before anything real can be deleted or replaced (L2).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if ! command -v security >/dev/null 2>&1 || ! command -v codesign >/dev/null 2>&1; then
  echo "SKIP build-install-preflight.test.sh: codesign/security unavailable (not macOS)"
  exit 0
fi

FAILURES=0
WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${WORK}"' EXIT

pass() { echo "ok - $1"; }
fail() { echo "FAIL - $1"; [[ -n "${2:-}" ]] && echo "  $2"; FAILURES=$((FAILURES + 1)); }

mkdir -p "${WORK}/mac/scripts"
cp "${MAC_DIR}/build-install.sh" "${WORK}/mac/build-install.sh"
cp -R "${MAC_DIR}/scripts/lib" "${WORK}/mac/scripts/lib"
chmod +x "${WORK}/mac/build-install.sh"

STUBS="${WORK}/stubs"
mkdir -p "${STUBS}"
for tool in xcodebuild xcodegen xcbeautify; do
  printf '#!/bin/sh\n: > "%s/ran-%s"\nexit 0\n' "${WORK}" "${tool}" > "${STUBS}/${tool}"
  chmod +x "${STUBS}/${tool}"
done

# Prove the stubs are reachable BEFORE asserting that they never ran. "The marker file is absent"
# and "the stub was never on PATH in the first place" are otherwise the same observation (L1/L100).
PATH="${STUBS}:${PATH}" xcodebuild -version >/dev/null 2>&1
PATH="${STUBS}:${PATH}" xcodegen --version >/dev/null 2>&1
if [[ -f "${WORK}/ran-xcodebuild" && -f "${WORK}/ran-xcodegen" ]]; then
  pass "the xcodebuild and xcodegen stubs are on PATH and record being run"
  rm -f "${WORK}/ran-xcodebuild" "${WORK}/ran-xcodegen"
else
  fail "the stubs did not record being run" \
       "every assertion below would then pass whether or not the pre-flight exists"
fi

# Two of the checks below read the ABSENCE of a progress line. An absent line proves nothing if the
# script no longer prints it at all, and the install one cannot be proven by mutation here (forcing
# it would mean letting the script replace the real /Applications/Overture.app), so the needles are
# checked against the script itself instead (L103).
for needle in '==> Building' '==> Installing to'; do
  if grep -qF "${needle}" "${WORK}/mac/build-install.sh"; then
    pass "build-install.sh still prints \"${needle}\", so its absence below means something"
  else
    fail "build-install.sh no longer prints \"${needle}\"" \
         "the absence check below would be watching for a line that can never appear"
  fi
done

missing_identity="No Such Overture Identity $$"
out="$(env PATH="${STUBS}:${PATH}" OVERTURE_SIGNING_IDENTITY="${missing_identity}" \
  bash "${WORK}/mac/build-install.sh" 2>&1)"
rc=$?

if [[ "${rc}" -ne 0 ]]; then
  pass "build-install.sh stops when the signing identity cannot be used (exit ${rc})"
else
  fail "build-install.sh carried on with an unusable signing identity" "out: ${out}"
fi

if [[ "${out}" == *"${missing_identity}"* ]]; then
  pass "it stops for the SIGNING reason, naming the identity"
else
  fail "it stopped without naming the signing identity" \
       "a stop for some other reason is not this guard working; got: ${out}"
fi

# The cheap half of #1526: no build was paid for. `==> Building` is build-install.sh's own line,
# printed immediately before xcodebuild.
if [[ -f "${WORK}/ran-xcodebuild" || "${out}" == *"==> Building"* ]]; then
  fail "it ran the build before checking the identity" \
       "the whole point is to fail before paying for a build; got: ${out}"
else
  pass "no build was run"
fi

# Earlier still than xcodebuild: xcodegen REWRITES mac/Overture.xcodeproj in the real checkout, so
# the check belongs above that too, not merely above the compile.
if [[ -f "${WORK}/ran-xcodegen" ]]; then
  fail "it regenerated the Xcode project before checking the identity" \
       "the check must come before anything that writes to the checkout"
else
  pass "no project regeneration was run"
fi

# The expensive half: the installed app must not have been touched. build-install.sh prints this
# line just before it boots out the login agent and deletes /Applications/Overture.app.
if [[ "${out}" == *"==> Installing to"* ]]; then
  fail "it reached the install step" "the installed copy is replaced there, before signing"
else
  pass "it never reached the install step"
fi

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "build-install-preflight.test.sh: all checks passed"
  exit 0
fi
echo "build-install-preflight.test.sh: ${FAILURES} failure(s)"
exit 1
