#!/usr/bin/env bash
set -uo pipefail

# #3110 / #3131: proves scripts/check-test-identity-provenance.sh against a throwaway git repository
# with real commits, rather than against a stub of `git log`. A stub could only ever confirm this
# fixture's own assumption about what git prints (L52), and the whole mechanism under test IS what git
# reports about a token's first appearance.
#
# The discriminator being proved: a name whose FIRST appearance is in a privacy scrub commit was minted
# by that scrub and is invented, and one whose first appearance is in an ordinary feature commit was
# written from real data and needs a person to look at it. Measured on 2026-08-22 across the eighteen
# names #2834 scrubbed, it separated every one of them correctly.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${SCRIPT_DIR}/check-test-identity-provenance.sh"
FAILURES=0

WORK="$(mktemp -d)"
MAIN_SHELL_PID="${BASHPID:-$$}"
trap '[ "${BASHPID:-$$}" = "${MAIN_SHELL_PID}" ] && rm -rf "${WORK}"' EXIT

REPO="${WORK}/repo"
mkdir -p "${REPO}/tests" "${REPO}/fixtures" "${REPO}/empty"
git -C "${REPO}" init --quiet
git -C "${REPO}" config user.name "Fixture"
git -C "${REPO}" config user.email "fixture@overture.example"

commit() { git -C "${REPO}" add -A && git -C "${REPO}" commit --quiet -m "$1"; }

# The FEATURE commit. Both of these arrive the way a test written from a real listing arrives: somebody
# copied a page. One is a person's name as the local part, the other is a person's name as the domain
# label, and #2839's domain rule can see neither, because both addresses sit on a reserved TLD.
mkdir -p "${REPO}/elsewhere"
cat > "${REPO}/tests/ScoutTests.swift" <<'SWIFT'
let organiser = "quillanbrackwater@example.com"
let performer = "hello@verrindale.example"
let room = "boxoffice@grandtheatre.example"
// A punctuated local part. Normalising this to one word before the lookup is the tidy-up that breaks
// the mechanism, because `git log -S` searches for a literal string and finds a normalised token in no
// commit anywhere, then reports that as "no commit found".
let dotted = "aldermoy.fenwrack@example.com"
SWIFT
# A fixture written somewhere else and moved under a scanned root later. A pathspec does not follow a
# rename, so the scoped lookup has no commit at the current path and the ORIGINAL commit is the answer.
cat > "${REPO}/elsewhere/moved.json" <<'JSON'
{"contact": "press@brammelcourt.example"}
JSON
commit "Pursue every performer a bill names (#1817)"
git -C "${REPO}" mv elsewhere/moved.json fixtures/moved.json
commit "Move the corpus under fixtures (#2000)"

# The SCRUB commit. It replaces one of the two identities above with an invented one, which is exactly
# how an invented name enters this repository.
sed -i.bak 's/quillanbrackwater/thessalyorne/' "${REPO}/tests/ScoutTests.swift"
rm -f "${REPO}/tests/ScoutTests.swift.bak"
commit "Scrub the real people the first privacy sweep could not see (#3114)"

BASELINE="${WORK}/baseline.txt"
: > "${BASELINE}"
export OVERTURE_IDENTITY_REPO="${REPO}"
export OVERTURE_IDENTITY_ROOTS="tests fixtures"
export OVERTURE_IDENTITY_BASELINE="${BASELINE}"

OUT="$("${CHECK}" 2>&1)"; STATUS=$?

# --- the provenance itself, which is the whole mechanism ---------------------------------------------
assert_contains "an identity minted by the scrub commit is reported with that commit" \
  "${OUT}" "thessalyorne"
assert_contains "the scrub-minted identity carries the scrub commit's own subject as its evidence" \
  "${OUT}" "Scrub the real people"
assert_contains "an identity introduced by a feature commit is reported" "${OUT}" "verrindale"
assert_contains "the feature-introduced identity carries the FEATURE commit's subject, not the scrub's" \
  "${OUT}" "Pursue every performer a bill names"
# BOTH halves of an address are identities. #2839 replaced only the DOMAIN, which is why a scrubbed
# person routinely survived as the local part of the very address that replaced them, so a reader of one
# half reports a scrub as finished when half of it has happened.
assert_contains "the domain label of a reserved-domain address is an identity" "${OUT}" "grandtheatre"
assert_contains "and so is its local part" "${OUT}" "boxoffice"
assert_equals "new identities to triage is its own exit status, not a pass" "1" "${STATUS}"

# The two ways the lookup can silently answer the wrong question, both of them wearing the shape of a
# real finding rather than of a broken lookup.
assert_contains "an identity whose local part carries punctuation is kept verbatim" \
  "${OUT}" "aldermoy.fenwrack"
assert_not_contains "and its provenance resolves rather than reading as unaccounted for" \
  "${OUT}" "PROVENANCE NOT RESOLVED"
# A pathspec does not follow a rename, so a lookup scoped to the scanned roots names the commit that
# MOVED the file as the identity's origin. That is wrong in the direction that matters: a move reads as
# recent and deliberate, while the write it hides may be far older and made from a real page.
MOVED_LINE="$(printf '%s\n' "${OUT}" | grep -A1 '^  brammelcourt$' | tail -1)"
assert_contains "a moved fixture's identity reports the commit that WROTE it" \
  "${MOVED_LINE}" "Pursue every performer a bill names"
assert_not_contains "not the commit that moved it" "${MOVED_LINE}" "Move the corpus"

# --- the baseline is what stops the same judgement being repeated from scratch ------------------------
"${CHECK}" --record >/dev/null 2>&1
RECORDED="$(cat "${BASELINE}")"
assert_contains "--record writes the identities it found" "${RECORDED}" "verrindale"
SECOND="$("${CHECK}" 2>&1)"; SECOND_STATUS=$?
assert_equals "a tree holding only already-triaged identities exits clean" "0" "${SECOND_STATUS}"
assert_not_contains "an already-triaged identity is not re-reported" "${SECOND}" "verrindale"

# A NEW identity arriving after the baseline was recorded is the whole point: it is named, and nothing
# else is, so the list a person reads is only ever what nobody has looked at yet.
cat > "${REPO}/fixtures/listing.json" <<'JSON'
{"contact": "press@ostrayfenwold.example"}
JSON
commit "Read the producing credits a listing states (#2677)"
THIRD="$("${CHECK}" 2>&1)"; THIRD_STATUS=$?
assert_contains "an identity added after the baseline is named" "${THIRD}" "ostrayfenwold"
assert_not_contains "and the already-triaged ones stay quiet" "${THIRD}" "verrindale"
assert_equals "a new arrival exits 1" "1" "${THIRD_STATUS}"

# --- a baseline line for an identity that is gone is a line to delete --------------------------------
printf 'akeleyworth\n' >> "${BASELINE}"
STALE="$("${CHECK}" 2>&1)"
assert_contains "a recorded identity no longer in the tree is named as a line to delete" \
  "${STALE}" "akeleyworth"

# --- nothing measured is its own answer, never a clean pass ------------------------------------------
# A roots path holding no addresses at all and a tree with genuinely nothing to look at leave the same
# empty result, and the emptiest possible failure must not read as the cleanest possible pass (L98).
UNMEASURED="$(OVERTURE_IDENTITY_ROOTS="empty" "${CHECK}" 2>&1)"; UNMEASURED_STATUS=$?
assert_equals "a scan that extracted no identity at all exits 2, not 0" "2" "${UNMEASURED_STATUS}"
assert_contains "and says so in words" "${UNMEASURED}" "UNMEASURED"
MISSING="$(OVERTURE_IDENTITY_ROOTS="does-not-exist" "${CHECK}" 2>&1)"; MISSING_STATUS=$?
assert_equals "a roots path that does not exist is unmeasured too" "2" "${MISSING_STATUS}"

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "FAILED: ${FAILURES} check-test-identity-provenance.sh assertion(s) failed"
  exit 1
fi
echo "All check-test-identity-provenance.sh fixtures passed"
