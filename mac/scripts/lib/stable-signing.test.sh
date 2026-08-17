#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"

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
if grep -q "Signature=adhoc" <<< "$(codesign -dvvv "${missing_bundle}" 2>&1)"; then
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

  if grep -q "Signature=adhoc" <<< "$(codesign -dvvv "${a}" 2>&1)"; then
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

# --- #1526: the pre-flight check that codesign will ACCEPT the identity ------------------------------
# build-install.sh used to discover an unusable identity only at the point of signing, after a full
# build had run and the working copy in /Applications had already been replaced. `overture_signing_
# identity_sha` cannot answer this: it asks whether an identity is LISTED, and on 2026-07-26 one was
# listed while codesign still answered "no identity found". So the pre-flight has to try a real sign.
if ! declare -f overture_verify_signing_identity_usable >/dev/null; then
  fail "overture_verify_signing_identity_usable is not defined" \
       "build-install.sh has no way to ask codesign whether it will accept the identity BEFORE building"
else
  # (a) MISSING identity: refuses, and says so in words that name the missing identity.
  missing_out="$(
    export OVERTURE_SIGNING_IDENTITY="No Such Overture Identity $$"
    export OVERTURE_SIGNING_KEYCHAIN=""
    overture_verify_signing_identity_usable 2>&1
  )"
  missing_rc=$?
  if [[ "${missing_rc}" -ne 0 && "${missing_out}" == *"not found"* ]]; then
    pass "pre-flight refuses a missing identity and names it (exit ${missing_rc})"
  else
    fail "pre-flight did not refuse a missing identity" "rc=${missing_rc} out: ${missing_out}"
  fi

  # (b) PRESENT but UNUSABLE, which is the whole point of #1526 and the case "is it listed?" cannot
  # see. Built from a real, self-signed code-signing certificate in a throwaway keychain that is
  # never trusted and never joins the search list, so `security find-identity` names it (with a real
  # SHA-1) while `codesign` refuses it outright. Nothing here is simulated except which listing the
  # name resolves through: the certificate, the keychain, and codesign's refusal are all real.
  if ! command -v openssl >/dev/null 2>&1; then
    echo "SKIP present-but-unusable check: openssl unavailable"
  else
    unusable_name="Overture Unusable Fixture Identity $$"
    unusable_kc="${WORK}/unusable.keychain-db"
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "${WORK}/unusable-key.pem" -out "${WORK}/unusable-cert.pem" -days 3650 \
      -subj "/CN=${unusable_name}" \
      -addext "keyUsage=critical,digitalSignature" \
      -addext "extendedKeyUsage=critical,codeSigning" \
      -addext "basicConstraints=critical,CA:false" >/dev/null 2>&1
    openssl pkcs12 -export -legacy \
      -inkey "${WORK}/unusable-key.pem" -in "${WORK}/unusable-cert.pem" \
      -out "${WORK}/unusable.p12" -passout "pass:transfer" \
      -name "${unusable_name}" >/dev/null 2>&1
    security create-keychain -p "unusable" "${unusable_kc}" >/dev/null 2>&1
    security unlock-keychain -p "unusable" "${unusable_kc}" >/dev/null 2>&1
    security import "${WORK}/unusable.p12" -k "${unusable_kc}" -P "transfer" -T /usr/bin/codesign \
      >/dev/null 2>&1
    trap 'security delete-keychain "'"${unusable_kc}"'" >/dev/null 2>&1; rm -rf "${WORK}"' EXIT
    unusable_sha="$(security find-identity -p codesigning "${unusable_kc}" 2>/dev/null \
      | awk -v n="${unusable_name}" 'index($0, n) { print $2; exit }')"

    if [[ -z "${unusable_sha}" ]]; then
      fail "could not build a present-but-unusable identity" \
           "security listed no identity named ${unusable_name} in ${unusable_kc}"
    else
      # Prove the premise before asserting anything on top of it: this identity really is one
      # codesign will not sign with. Without this the next check could pass on a bundle codesign
      # was perfectly happy to sign.
      premise_bundle="${WORK}/premise.app"
      make_bundle "${premise_bundle}"
      premise_out="$(codesign --force --sign "${unusable_sha}" "${premise_bundle}" 2>&1)"
      if [[ $? -ne 0 ]]; then
        pass "premise holds: codesign refuses this identity (${premise_out})"
      else
        fail "premise broken: codesign accepted the identity meant to be unusable" \
             "the present-but-unusable check below would prove nothing"
      fi

      # The subshell below shadows only the LISTING, with the REAL SHA-1 that security just printed
      # for this identity. That is exactly the reported state: the listing names an identity and
      # codesign refuses it. (No comments inside the $( ) below: bash 3.2 mis-parses an apostrophe
      # in a comment inside a command substitution and reports an unmatched quote at that line.)
      unusable_out="$(
        export OVERTURE_SIGNING_IDENTITY="${unusable_name}"
        export OVERTURE_SIGNING_KEYCHAIN="${unusable_kc}"
        overture_signing_identity_sha() { printf '%s\n' "${unusable_sha}"; }
        overture_verify_signing_identity_usable 2>&1
      )"
      unusable_rc=$?
      if [[ "${unusable_out}" == *"command not found"* ]]; then
        fail "pre-flight call did not resolve to a function" "got: ${unusable_out}"
      elif [[ "${unusable_rc}" -ne 0 ]]; then
        pass "pre-flight refuses an identity that is listed but will not sign (exit ${unusable_rc})"
      else
        fail "pre-flight passed an identity codesign refuses" \
             "this is the #1526 defect: the failure surfaces after the build, mid-install"
      fi
      if [[ "${unusable_out}" == *"will not sign with it"* ]]; then
        pass "pre-flight says the identity exists but codesign will not use it"
      else
        fail "pre-flight did not distinguish unusable from missing" "got: ${unusable_out}"
      fi
      if [[ "${unusable_out}" == *"${unusable_sha}"* ]]; then
        pass "pre-flight names which identity codesign refused"
      else
        fail "pre-flight did not name the refused identity" "got: ${unusable_out}"
      fi
    fi
  fi

  # (c) A USABLE identity passes, and the probe leaves nothing behind. A guard that fails closed
  # forever is still a guard that does not work: this is what proves the check is not simply
  # refusing everything.
  if [[ -z "${existing}" ]]; then
    echo "SKIP pre-flight accepts-a-usable-identity check: no valid codesigning identity here"
  else
    probe_tmp="${WORK}/probe-tmp"
    mkdir -p "${probe_tmp}"
    usable_out="$(
      export OVERTURE_SIGNING_IDENTITY="${existing}"
      export OVERTURE_SIGNING_KEYCHAIN=""
      export TMPDIR="${probe_tmp}"
      overture_verify_signing_identity_usable 2>&1
    )"
    usable_rc=$?
    if [[ "${usable_rc}" -eq 0 ]]; then
      pass "pre-flight accepts an identity codesign will actually use"
    else
      fail "pre-flight refused a usable identity (it would block every install)" \
           "rc=${usable_rc} out: ${usable_out}"
    fi
    leftovers="$(find "${probe_tmp}" -mindepth 1 2>/dev/null | head -5)"
    if [[ -z "${leftovers}" ]]; then
      pass "pre-flight cleans up its throwaway bundle"
    else
      fail "pre-flight left its probe behind" "found: ${leftovers}"
    fi
  fi
fi

# --- #2595: counting the certificates that carry the identity's name --------------------------------
#
# The count exists to notice something find-identity structurally cannot see: a certificate codesign
# refuses is not listed by `find-identity -v` at all, so the run that replaces it cannot tell whether it
# left one behind. These two cases pin the branch that needs no keychain at all, since it is the one a
# first run takes and the one that must never report a failure to read as a count.

COUNT_OUT="$(
  export OVERTURE_SIGNING_IDENTITY="Overture Fixture Signing"
  export OVERTURE_SIGNING_KEYCHAIN=""
  overture_signing_certificate_count 2>&1
)"
assert_equals "with no keychain configured the count is 0, not an error" "0" "${COUNT_OUT}"

# UNSET, not empty, and under `set -u`: the #1711 shape. The count is called before anything is created,
# which is exactly when this variable can be missing, and a function that dies here would take the whole
# setup script with it and say nothing about signing at all. Written as the case that fails if the guard
# at the top of the function is removed, since an empty value alone cannot tell the two apart: `security`
# answers 0 for an empty and for a nonexistent keychain either way.
COUNT_OUT="$(
  set -u
  export OVERTURE_SIGNING_IDENTITY="Overture Fixture Signing"
  unset OVERTURE_SIGNING_KEYCHAIN
  overture_signing_certificate_count 2>&1
  echo "|survived"
)"
assert_contains "an UNSET keychain variable answers 0 rather than killing the caller" "${COUNT_OUT}" "0|survived"

COUNT_OUT="$(
  export OVERTURE_SIGNING_IDENTITY="Overture Fixture Signing"
  export OVERTURE_SIGNING_KEYCHAIN="${TMPDIR:-/tmp}/overture-no-such-keychain-$$.keychain-db"
  overture_signing_certificate_count 2>&1
)"
assert_equals "a keychain file that does not exist counts 0 rather than failing" "0" "${COUNT_OUT}"

# It must also be read only. A count that created the keychain it was asked about would make the
# first-run message a lie the moment anything asked for it.
PROBE_KC="${TMPDIR:-/tmp}/overture-count-probe-$$.keychain-db"
(
  export OVERTURE_SIGNING_IDENTITY="Overture Fixture Signing"
  export OVERTURE_SIGNING_KEYCHAIN="${PROBE_KC}"
  overture_signing_certificate_count >/dev/null 2>&1
)
if [[ -e "${PROBE_KC}" ]]; then
  fail "counting certificates created a keychain" "at ${PROBE_KC}"
  rm -f "${PROBE_KC}"
else
  pass "counting certificates creates nothing"
fi

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "stable-signing.test.sh: all checks passed"
  exit 0
fi
echo "stable-signing.test.sh: ${FAILURES} failure(s)"
exit 1
