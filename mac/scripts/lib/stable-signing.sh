#!/usr/bin/env bash
# Stable local code signing for the installed Release bundle (#1425).
#
# macOS keys TCC permission grants (calendar, Gmail/automation, reminders, notifications) for an
# unsigned or ad-hoc-signed app on its cdhash, which is a hash of the binary and therefore changes on
# every rebuild. build-install.sh used to ad-hoc re-sign the installed bundle ("codesign --sign -"),
# under a comment claiming that made the identity stable; it does the opposite. Every reinstall then
# presented a different cdhash, so macOS silently dropped or re-prompted a grant Dan had already given.
#
# Signing with a stable self-signed certificate instead gives TCC a constant designated requirement
# (keyed on the certificate, not the binary) that survives rebuilds, so the grants persist. The cert
# lives in a dedicated keychain the setup script owns; see setup-signing-identity.sh. This file only
# defines functions (safe to source) and is used by both that setup and build-install.sh.

# The certificate's common name, the keychain that holds it, and that keychain's password. The
# password is a local, non-sensitive constant: it locks a self-signed certificate used only to give
# this Mac a stable code-signing identity, not any external credential. All three are overridable so
# the fixture can point them at a throwaway.
: "${OVERTURE_SIGNING_IDENTITY:=Overture Local Signing}"
# #1711: HOME through a guard rather than directly. build-install.sh declares `set -euo pipefail` and is
# reached from the app's own Update button, so a bare ${HOME} here aborted the install with the shell's
# "HOME: unbound variable" and nothing about signing at all. A keychain has no sensible location without
# HOME, so this refuses rather than guessing one, in the same spirit as the identity check below: never
# carry on toward an ad-hoc signature, which is the silent-drop trap #1425 is about.
if [ -z "${OVERTURE_SIGNING_KEYCHAIN:-}" ]; then
  if [ -z "${HOME:-}" ]; then
    echo "Cannot tell where the Overture signing keychain lives: HOME is not set in this environment." >&2
    echo "  Set HOME to the account's home folder, or set OVERTURE_SIGNING_KEYCHAIN to the keychain file, then run this again." >&2
    exit 1
  fi
  OVERTURE_SIGNING_KEYCHAIN="${HOME}/Library/Keychains/overture-signing.keychain-db"
fi
: "${OVERTURE_SIGNING_KEYCHAIN_PASSWORD:=overture-local-signing}"

# Prints the SHA-1 of the valid (trusted) "${OVERTURE_SIGNING_IDENTITY}" code-signing identity, or
# nothing if it is absent. "-v" lists only valid identities, which is what codesign will accept and
# what the setup script's trust step produces. The ${scope[@]+...} guard keeps an empty array from
# tripping "unbound variable" under set -u in macOS's bash 3.2.
# #1524: the self-signed certificate the identity is built from. It lives here, as a function, so its
# SHAPE can be tested without a keychain, a trust store, or the password dialog the real setup needs.
#
# The first version of this was inline in setup-signing-identity.sh and set no keyUsage extension at all.
# macOS's code-signing policy requires the Digital Signature bit, so `find-identity` listed the identity
# as "(Invalid Key Usage for policy)" and `codesign` answered "no identity found": the setup reported
# success, and every install then silently kept its ad-hoc build signature, which is the exact trap #1425
# was written to close. Diagnosed against a self-signed cert on the same Mac that codesign DOES accept;
# the two differences were this extension and marking the extended usage critical.
overture_generate_signing_cert() {
  local keyout="$1" certout="$2"
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${keyout}" -out "${certout}" -days 3650 \
    -subj "/CN=${OVERTURE_SIGNING_IDENTITY}" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" >/dev/null 2>&1
}

overture_signing_identity_sha() {
  local -a scope=()
  if [[ -n "${OVERTURE_SIGNING_KEYCHAIN:-}" && -f "${OVERTURE_SIGNING_KEYCHAIN}" ]]; then
    scope=("${OVERTURE_SIGNING_KEYCHAIN}")
  fi
  security find-identity -v -p codesigning ${scope[@]+"${scope[@]}"} 2>/dev/null \
    | awk -v name="\"${OVERTURE_SIGNING_IDENTITY}\"" 'index($0, name) { print $2; exit }'
}

# Signs the bundle with the stable identity. FAILS LOUD (nonzero, no signature written) when the
# identity is missing: an ad-hoc fallback is exactly the silent-drop trap #1425 is about, so it is
# never taken. On success the bundle carries a cert-keyed designated requirement stable across rebuilds.
overture_stable_sign() {
  local bundle="$1"
  local sha
  sha="$(overture_signing_identity_sha)"
  if [[ -z "${sha}" ]]; then
    echo "ERROR: stable signing identity \"${OVERTURE_SIGNING_IDENTITY}\" not found." >&2
    echo "       Run mac/scripts/setup-signing-identity.sh once to create it." >&2
    echo "       Refusing to ad-hoc sign: that silently drops macOS permission grants on reinstall (#1425)." >&2
    return 1
  fi
  if [[ -n "${OVERTURE_SIGNING_KEYCHAIN:-}" && -f "${OVERTURE_SIGNING_KEYCHAIN}" ]]; then
    # Unlock the dedicated keychain so its private key is reachable. setup-signing-identity.sh keeps
    # that keychain in the search list, so codesign resolves the identity from there with no
    # --keychain scope, the same search-list path the fixture exercises.
    security unlock-keychain -p "${OVERTURE_SIGNING_KEYCHAIN_PASSWORD}" "${OVERTURE_SIGNING_KEYCHAIN}" >/dev/null 2>&1 || true
  fi
  codesign --force --deep --sign "${sha}" "${bundle}"
}
