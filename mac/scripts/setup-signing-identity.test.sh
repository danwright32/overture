#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/shell-assertions.sh"

# #2537: setup-signing-identity.sh used to finish by asking whether an identity was LISTED, and then
# print `Done. Created and trusted ...`. That is the cheaper question, and it is the one #1526 removed
# from build-install.sh for being wrong.
#
# It is the script that lied first. On 2026-07-26 it printed that Done line for a certificate codesign
# then refused outright (the missing Digital Signature key usage, fixed in #1525), and only
# build-install.sh found out, after a full Release build and after /Applications/Overture.app had already
# been replaced.
#
# The reason it went unfixed in #1526 was that it had no honest test: the script calls
# `security add-trusted-cert`, which opens a macOS Certificate Trust Settings password dialog, so it
# cannot be driven end to end. This file is the answer to that. Every call that touches the real keychain
# or the real trust store now lives behind a named function, the way app-quit.sh does with
# `app_quit_kill` and `app_quit_tick`, so the script's whole decision path can be driven here with those
# three replaced and nothing else faked. What is under test is which question the script asks and what it
# does with each answer, which is exactly where the defect was.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="${SCRIPT_DIR}/setup-signing-identity.sh"

FAILURES=0
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Runs the real script's entry point in a subshell with the three keychain seams replaced by recorders,
# and the two identity questions answered as this case wants. Prints the script's output, then a line
# giving its exit status and one naming each seam that actually ran, so a case can assert on what the
# script DID as well as on what it said.
#
# `usable` is what overture_verify_signing_identity_usable answers, and `listed` is what
# overture_signing_identity_sha answers, because the whole point of the issue is that those are two
# different questions and the script had been asking the weaker one.
# #2595 adds a fourth argument, `certs_already_there`: how many certificates with this common name the
# keychain already holds. It defaults to 0 so every case written before it keeps meaning what it meant.
run_setup() {
  local usable_before="$1" usable_after="$2" listed="$3" certs_already_there="${4:-0}"
  (
    export OVERTURE_SIGNING_KEYCHAIN="${TMP}/throwaway.keychain-db"
    export OVERTURE_SIGNING_IDENTITY="Overture Fixture Signing"
    # shellcheck source=./setup-signing-identity.sh
    source "${SETUP}"

    overture_signing_certificate_count() { printf '%s' "${certs_already_there}"; }

    RAN=""
    overture_setup_prepare_keychain() { RAN="${RAN} prepare_keychain"; }
    overture_setup_import_identity() { RAN="${RAN} import_identity"; }
    overture_setup_trust_certificate() { RAN="${RAN} trust_certificate"; }
    overture_generate_signing_cert() { printf 'key\n' > "$1"; printf 'cert\n' > "$2"; }
    # The real one shells out to openssl to build a PKCS#12; nothing about it is under test here and it
    # would only slow the fixture down.
    overture_setup_package_identity() { RAN="${RAN} package_identity"; }

    overture_signing_identity_sha() { printf '%s' "${listed}"; }

    CALLS=0
    overture_verify_signing_identity_usable() {
      CALLS=$((CALLS + 1))
      local answer="${usable_before}"
      [[ "${CALLS}" -gt 1 ]] && answer="${usable_after}"
      if [[ "${answer}" == "yes" ]]; then
        return 0
      fi
      echo "ERROR: signing identity is listed, but codesign will not sign with it." >&2
      return 1
    }

    rc=0
    overture_setup_signing_identity || rc=$?
    echo "EXIT=${rc}"
    echo "RAN=${RAN}"
  ) 2>&1
}

# --- the defect itself -------------------------------------------------------------------------------
#
# An identity that gets created and then refused by codesign. This is 2026-07-26 exactly.

OUT="$(run_setup "no" "no" "ABC123")"

assert_contains "a created identity codesign refuses fails the setup" "${OUT}" "EXIT=1"
assert_not_contains "and the setup never claims it is done" "${OUT}" "Done."
assert_not_contains "and never claims it was trusted" "${OUT}" "Created and trusted"
assert_contains "and it says codesign is what refused" "${OUT}" "codesign will not sign with it"

# --- the working path --------------------------------------------------------------------------------

OUT="$(run_setup "no" "yes" "ABC123")"

assert_contains "an identity codesign accepts finishes successfully" "${OUT}" "EXIT=0"
assert_contains "and only then says it is done" "${OUT}" "Done."
assert_contains "and it did the work" "${OUT}" "trust_certificate"

# --- #2595: it says WHICH of the two things it is doing -----------------------------------------------
#
# Since #2537 the early exit asks whether codesign will SIGN with the identity, not whether one is
# listed, so a certificate that exists and is refused no longer stops the run: it falls through and
# creates a fresh one. `security find-identity -v` cannot see the broken one, so nothing deletes it and
# both end up in the keychain, with the new trusted one winning every lookup.
#
# Measured on this Mac, 2026-08-13: exactly one certificate carries the name, so no accumulation has
# happened and no deletion logic is warranted. What was missing is that the two runs are
# indistinguishable from the outside, and one of them silently leaves a second certificate behind.

OUT="$(run_setup "no" "yes" "ABC123" 0)"
assert_contains "a first-time run says it is creating the first certificate" \
  "${OUT}" "No certificate named"
assert_not_contains "and does not talk about certificates that are already there" \
  "${OUT}" "already in the keychain"
assert_contains "and its Done line says how many now carry the name" "${OUT}" "Keychain Access now shows 1"

OUT="$(run_setup "no" "yes" "ABC123" 1)"
assert_contains "a replacing run says one is already there" "${OUT}" "1 already in the keychain"
assert_contains "and says plainly that it is not deleting it" "${OUT}" "does not delete"
assert_contains "and its Done line says the count it leaves behind" "${OUT}" "Keychain Access now shows 2"

# Two already there is the state this issue was written to detect. The message must count what it found
# rather than assume one, or the report would understate exactly the accumulation it exists to surface.
OUT="$(run_setup "no" "yes" "ABC123" 2)"
assert_contains "it counts what it found rather than assuming one" "${OUT}" "2 already in the keychain"
assert_contains "and says what the count will be afterwards" "${OUT}" "Keychain Access now shows 3"

# The early exit must stay silent about all of this: nothing was created, so there is nothing to report,
# and a count printed there would read as though something had happened.
OUT="$(run_setup "yes" "yes" "ABC123" 1)"
assert_contains "an already-working identity still just says there is nothing to do" "${OUT}" "Nothing to do"
assert_not_contains "and says nothing about creating or counting certificates" "${OUT}" "Keychain Access now shows"

# --- nothing to do -----------------------------------------------------------------------------------
#
# The early exit has to ask the SAME question as the final check. Asking the weaker one here would put
# the identical lie one step earlier: an identity that is listed and refused would be reported as already
# set up, and the person would be sent away with nothing fixed.

OUT="$(run_setup "yes" "yes" "ABC123")"

assert_contains "an identity that already signs exits successfully" "${OUT}" "EXIT=0"
assert_contains "and says there is nothing to do" "${OUT}" "Nothing to do"
assert_not_contains "and touches no keychain" "${OUT}" "prepare_keychain"
assert_not_contains "and asks for no password dialog" "${OUT}" "trust_certificate"

# --- listed, and refused -----------------------------------------------------------------------------
#
# The case the issue names: an identity that IS listed but that codesign will not use. The old early exit
# read `overture_signing_identity_sha` and would have stopped here reporting success.

OUT="$(run_setup "no" "yes" "ABC123")"

assert_not_contains "a listed but refused identity is not called already set up" "${OUT}" "Nothing to do"
assert_contains "it is recreated instead" "${OUT}" "trust_certificate"
assert_contains "and the run succeeds once codesign accepts the new one" "${OUT}" "EXIT=0"

# --- the private key does not survive a failure ------------------------------------------------------
#
# The scratch directory holds the certificate's PRIVATE KEY. A run that dies part way through, which is
# the case this whole issue is about, must not leave it lying in the temp directory (L19).

SCRATCH_RECORD="${TMP}/scratch-path"
FAILED_RUN="$(
  export OVERTURE_SIGNING_KEYCHAIN="${TMP}/throwaway.keychain-db"
  export OVERTURE_SIGNING_IDENTITY="Overture Fixture Signing"
  # shellcheck source=./setup-signing-identity.sh
  source "${SETUP}"

  overture_setup_prepare_keychain() { :; }
  overture_setup_package_identity() { :; }
  overture_setup_import_identity() { :; }
  overture_generate_signing_cert() { printf 'key\n' > "$1"; printf 'cert\n' > "$2"; }
  # Records where the scratch directory was, then fails the way the real trust step can.
  overture_setup_trust_certificate() {
    dirname "$1" > "${SCRATCH_RECORD}"
    return 1
  }
  overture_signing_identity_sha() { printf 'ABC123'; }
  overture_verify_signing_identity_usable() { return 1; }

  rc=0
  overture_setup_signing_identity || rc=$?
  echo "EXIT=${rc}"
)"

assert_contains "a run that dies part way through fails" "${FAILED_RUN}" "EXIT=1"
SCRATCH_DIR="$(cat "${SCRATCH_RECORD}" 2>/dev/null || echo "")"
if [[ -z "${SCRATCH_DIR}" ]]; then
  fail "the fixture never reached the trust step" "so it cannot say whether the key was cleaned up"
elif [[ -e "${SCRATCH_DIR}" ]]; then
  fail "the private key was left behind at ${SCRATCH_DIR}"
else
  pass "the scratch directory holding the private key is gone"
fi

# --- source safety -----------------------------------------------------------------------------------
#
# Sourcing the script must define its functions and do nothing else, or this fixture would itself create
# a keychain and open a password dialog on the machine running it (L2).

SOURCE_OUT="$(
  export OVERTURE_SIGNING_KEYCHAIN="${TMP}/never-created.keychain-db"
  # shellcheck source=./setup-signing-identity.sh
  source "${SETUP}"
  echo "sourced"
)"
assert_contains "sourcing the script runs none of it" "${SOURCE_OUT}" "sourced"
assert_not_contains "and creates nothing" "${SOURCE_OUT}" "Creating dedicated signing keychain"
if [[ -e "${TMP}/never-created.keychain-db" ]]; then
  fail "sourcing the script created a keychain on this machine"
else
  pass "sourcing the script created no keychain"
fi

# --- the question it asks ----------------------------------------------------------------------------
#
# The whole issue in one assertion: the final check must be the trial sign, not the listing. Driven
# rather than grepped, by answering "listed" yes and "usable" no and requiring the script to fail: a
# script that still asked the weaker question would report success on exactly this input.

OUT="$(run_setup "no" "no" "DEADBEEF")"
assert_contains "a listed identity is not enough to report success" "${OUT}" "EXIT=1"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All setup-signing-identity.sh fixtures passed."
  exit 0
else
  echo "${FAILURES} setup-signing-identity.sh fixture(s) failed."
  exit 1
fi
