#!/usr/bin/env bash
set -uo pipefail

# #1524: the certificate setup-signing-identity.sh generates was REJECTED by codesign, so every install
# fell back to the ad-hoc signature #1425 exists to avoid, and Dan's permissions kept re-prompting.
#
# The symptom on his Mac: `security find-identity -v -p codesigning` listed
#     E701D57D... "Overture Local Signing" (Invalid Key Usage for policy)
# and `codesign --sign E701D57D...` answered "no identity found". So the setup script reported success,
# build-install.sh reported "no identity found", and the bundle kept its ad-hoc build signature.
#
# Diagnosed by comparing against a self-signed code-signing cert on the SAME Mac that codesign does
# accept ("PostRoll Local Signing"). Two differences, both in this file's fix:
#
#   |                     | works                        | Overture's                  |
#   | Key Usage           | critical, Digital Signature  | ABSENT                      |
#   | Extended Key Usage  | critical, Code Signing       | Code Signing, not critical  |
#
# macOS's code-signing policy requires the Digital Signature key-usage bit, which is what "Invalid Key
# Usage for policy" names. The old cert set no keyUsage extension at all.
#
# This tests the certificate's SHAPE, deliberately, because that can be checked without a keychain, a
# trust store or the password dialog the real setup needs. The previous coverage only asked whether an
# identity EXISTED, which is why a cert codesign would refuse still read as a pass.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v openssl >/dev/null 2>&1; then
  echo "SKIP signing-cert.test.sh: openssl unavailable"
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

if ! declare -f overture_generate_signing_cert >/dev/null; then
  fail "overture_generate_signing_cert is not defined" \
       "the cert generation must live in a function so its shape is testable at all"
  echo "${FAILURES} failure(s)"
  exit 1
fi

overture_generate_signing_cert "${WORK}/key.pem" "${WORK}/cert.pem"
if [[ ! -s "${WORK}/cert.pem" ]]; then
  fail "generated no certificate"
  echo "${FAILURES} failure(s)"
  exit 1
fi
pass "generates a certificate"

text="$(openssl x509 -in "${WORK}/cert.pem" -noout -text 2>/dev/null)"

# THE bug. Without this extension macOS reports "Invalid Key Usage for policy" and codesign refuses the
# identity outright, which is indistinguishable from it not existing.
if grep -A1 "X509v3 Key Usage: critical" <<<"${text}" | grep -q "Digital Signature"; then
  pass "carries a critical Digital Signature key usage (what codesign requires)"
else
  fail "no critical Digital Signature key usage" \
       "codesign rejects the identity: 'Invalid Key Usage for policy'"
fi

# The working cert marks this critical too. Left un-critical, a verifier is free to ignore the one
# extension that says what the certificate is FOR.
if grep -A1 "X509v3 Extended Key Usage: critical" <<<"${text}" | grep -q "Code Signing"; then
  pass "carries a critical Code Signing extended key usage"
else
  fail "extended key usage is missing or not critical" \
       "the cert must assert, critically, that it is for code signing"
fi

# Unchanged, and still required: a leaf certificate, never a CA.
if grep -A1 "X509v3 Basic Constraints: critical" <<<"${text}" | grep -q "CA:FALSE"; then
  pass "is a leaf certificate, not a CA"
else
  fail "basic constraints missing or not CA:FALSE"
fi

# The common name is what find-identity and codesign look the identity up BY, so it has to be the name
# the rest of the tooling agrees on rather than whatever openssl was last asked for.
if grep -q "CN *= *${OVERTURE_SIGNING_IDENTITY}" <<<"${text}"; then
  pass "is named \"${OVERTURE_SIGNING_IDENTITY}\", the name the tooling looks up"
else
  fail "common name is not \"${OVERTURE_SIGNING_IDENTITY}\"" \
       "$(grep -m1 "Subject:" <<<"${text}")"
fi

# A private key alongside it, or there is no identity to sign with, only a certificate.
if [[ -s "${WORK}/key.pem" ]] && openssl pkey -in "${WORK}/key.pem" -noout 2>/dev/null; then
  pass "emits a usable private key beside the certificate"
else
  fail "no usable private key written"
fi

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "signing-cert.test.sh: all checks passed"
else
  echo "${FAILURES} failure(s)"
fi
exit $(( FAILURES > 0 ? 1 : 0 ))
