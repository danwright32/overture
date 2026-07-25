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
: "${OVERTURE_SIGNING_KEYCHAIN:=${HOME}/Library/Keychains/overture-signing.keychain-db}"
: "${OVERTURE_SIGNING_KEYCHAIN_PASSWORD:=overture-local-signing}"

# Prints the SHA-1 of the valid (trusted) "${OVERTURE_SIGNING_IDENTITY}" code-signing identity, or
# nothing if it is absent. "-v" lists only valid identities, which is what codesign will accept and
# what the setup script's trust step produces. The ${scope[@]+...} guard keeps an empty array from
# tripping "unbound variable" under set -u in macOS's bash 3.2.
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
