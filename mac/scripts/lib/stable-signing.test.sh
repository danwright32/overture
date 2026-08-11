#!/usr/bin/env bash
set -uo pipefail

# Coverage for stable-signing.sh (#1425). The installed Release bundle used to be ad-hoc re-signed,
# whose cdhash is a hash of the binary and so changes on every rebuild; macOS keys TCC permission
# grants for an ad-hoc/unsigned app on that cdhash, so a reinstall silently dropped Dan's calendar,
# Gmail and automation grants. overture_stable_sign signs with a stable, cert-keyed identity instead.
# Two guarantees to pin: (1) it signs with a stable, cert-keyed identity that is IDENTICAL across a
# rebuild (a differing binary), and (2) it FAILS LOUD when that identity is missing rather than
# falling back to ad-hoc (the silent-drop trap the old code fell into).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v codesign >/dev/null 2>&1 || ! command -v security >/dev/null 2>&1; then
  echo "SKIP stable-signing.test.sh: codesign/security unavailable (not macOS)"
  exit 0
fi

# shellcheck source=./stable-signing.sh
source "${SCRIPT_DIR}/stable-signing.sh"
set +e

FAILURES=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

pass() { echo "ok - $1"; }
fail() { echo "FAIL - $1"; [[ -n "${2:-}" ]] && echo "  $2"; FAILURES=$((FAILURES + 1)); }

# A minimal signable bundle: an executable and an Info.plist naming it.
make_bundle() {
  local dir="$1"
  mkdir -p "${dir}/Contents/MacOS"
  printf '#!/bin/sh\ntrue\n' > "${dir}/Contents/MacOS/tool"
  chmod +x "${dir}/Contents/MacOS/tool"
  printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.danwright.overture.test</string><key>CFBundleExecutable</key><string>tool</string></dict></plist>' \
    > "${dir}/Contents/Info.plist"
}

# --- (2) fail loud when the identity is missing, never ad-hoc ---------------------------------------
missing_bundle="${WORK}/missing.app"
make_bundle "${missing_bundle}"
(
  export OVERTURE_SIGNING_IDENTITY="No Such Overture Identity $$"
  export OVERTURE_SIGNING_KEYCHAIN=""
  overture_stable_sign "${missing_bundle}" >/dev/null 2>&1
)
rc=$?
if [[ "${rc}" -ne 0 ]]; then
  pass "refuses to sign when the stable identity is missing (exit ${rc})"
else
  fail "signed anyway when the identity was missing (should fail loud, not ad-hoc)"
fi
if codesign -dvvv "${missing_bundle}" 2>&1 | grep -q "Signature=adhoc"; then
  fail "fell back to an ad-hoc signature, exactly the silent-drop trap #1425 is about"
else
  pass "left the bundle without an ad-hoc signature"
fi

# --- (1) stable, cert-keyed signature identical across a rebuild ------------------------------------
# Use whatever valid codesigning identity this Mac already has as a stand-in for the dedicated one;
# skip where none exists (a fresh Mac, or CI), since creating+trusting one needs interactive auth.
existing="$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"[^"]+"' | head -1 | tr -d '"')"
if [[ -z "${existing}" ]]; then
  echo "SKIP stable-sign checks: no valid codesigning identity on this machine"
else
  a="${WORK}/a.app"; make_bundle "${a}"
  b="${WORK}/b.app"; make_bundle "${b}"; printf ' ' >> "${b}/Contents/Info.plist"  # a differing binary
  export OVERTURE_SIGNING_IDENTITY="${existing}"
  export OVERTURE_SIGNING_KEYCHAIN=""
  overture_stable_sign "${a}" >/dev/null 2>&1 || fail "stable sign of a.app failed"
  overture_stable_sign "${b}" >/dev/null 2>&1 || fail "stable sign of b.app failed"

  if codesign -dvvv "${a}" 2>&1 | grep -q "Signature=adhoc"; then
    fail "signed ad-hoc despite a valid identity being available"
  else
    pass "signed with a real identity, not ad-hoc"
  fi

  dr_a="$(codesign -d -r- "${a}" 2>&1 | grep -i 'designated =>')"
  dr_b="$(codesign -d -r- "${b}" 2>&1 | grep -i 'designated =>')"
  if [[ -n "${dr_a}" && "${dr_a}" == *certificate* ]]; then
    pass "designated requirement is cert-keyed (survives a cdhash change)"
  else
    fail "designated requirement is not cert-keyed" "got: ${dr_a}"
  fi
  if [[ "${dr_a}" == "${dr_b}" ]]; then
    pass "same designated requirement across a rebuild (the whole point: grants persist)"
  else
    fail "designated requirement changed across a rebuild" "a: ${dr_a}\n  b: ${dr_b}"
  fi
fi

# --- #1711: sourced into a shell whose environment carries no HOME -----------------------------------
# build-install.sh declares `set -euo pipefail` and is reached from the app's own Update button, so the
# bare ${HOME} in the keychain default aborted the install with the shell's "HOME: unbound variable" and
# nothing about signing at all. The keychain has no sensible location without HOME, so refusing is
# right; refusing in words that name what is missing is what this pins.
out="$(env -u HOME -u OVERTURE_SIGNING_KEYCHAIN bash -c \
  'set -euo pipefail; . "'"${SCRIPT_DIR}"'/stable-signing.sh"; echo survived' 2>&1)"
if [[ "${out}" == *"unbound variable"* ]]; then
  fail "no HOME: refuses in its own words, not the shell's" "got: ${out}"
else
  pass "no HOME: refuses in its own words, not the shell's"
fi
if [[ "${out}" == *"HOME is not set"* ]]; then
  pass "no HOME: names what is missing"
else
  fail "no HOME: names what is missing" "got: ${out}"
fi
if [[ "${out}" == *survived* ]]; then
  fail "no HOME: stops rather than signing against an unresolvable keychain path" "got: ${out}"
else
  pass "no HOME: stops rather than signing against an unresolvable keychain path"
fi

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "stable-signing.test.sh: all checks passed"
  exit 0
fi
echo "stable-signing.test.sh: ${FAILURES} failure(s)"
exit 1
