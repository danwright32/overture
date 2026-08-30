#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501).
# shellcheck source=./lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"

# Coverage for scripts/find-tests-naming.sh (#3163): every test naming a symbol, attributed to the test
# rather than to the file, so a reversed decision can be implemented against the full set.
#
# The unit is the TEST, and that is the whole value over `grep -rl`: 14 files name `isAwaitingNudge` in
# this repository and the thing somebody has to decide about is each test inside them.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIND="${SCRIPT_DIR}/find-tests-naming.sh"
WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${WORK}"' EXIT
FAILURES=0

mkdir -p "${WORK}/tests"
cat > "${WORK}/tests/NudgeTests.swift" <<'SWIFT'
import Testing

@Suite("Nudges stop when the show does")
struct NudgesStopWhenTheShowDoesTests {

    // A helper, outside any test. Anything it names belongs to the SUITE, not to whichever test
    // happens to be written above it.
    private func recipient() -> Recipient { Recipient(isAwaitingNudge: true) }

    @Test func aShowStillAheadKeepsItsNudge() {
        #expect(recipient().isAwaitingNudge)
    }

    @Test func aShowThatHasBeenAndGoneIsNoLongerNudged() {
        #expect(!laterShow().isAwaitingNudge)
    }

    // A COMMENT asserting the old rule reads as misleadingly as an assertion does, so it is reported
    // the same way: a dismissed show that was emailed is still isAwaitingNudge.
    @Test func somethingElseEntirely() {
        #expect(true)
    }
}
SWIFT
cat > "${WORK}/tests/OtherTests.swift" <<'SWIFT'
import Testing

@Suite("Something unrelated")
struct SomethingUnrelatedTests {
    @Test func namesNothingOfInterest() { #expect(true) }
}
SWIFT

export OVERTURE_TEST_ROOTS="${WORK}/tests"
OUT="$("${FIND}" isAwaitingNudge 2>&1)"; STATUS=$?

# --- the attribution, which is the whole point ------------------------------------------------------
assert_equals "a symbol that is named somewhere exits 0" "0" "${STATUS}"
assert_contains "the test that names it is named, not just its file" \
  "${OUT}" "aShowStillAheadKeepsItsNudge"
assert_contains "and so is a second test in the same file" \
  "${OUT}" "aShowThatHasBeenAndGoneIsNoLongerNudged"
assert_contains "the file is still named, because that is where the reader has to go" \
  "${OUT}" "NudgeTests.swift"

# A mention in a helper belongs to the SUITE and says so, rather than being attributed to whichever test
# was declared above it, which would send the reader to a test that does not mention it at all (L11).
assert_contains "a mention outside any test is attributed to the suite" \
  "${OUT}" "NudgesStopWhenTheShowDoesTests"
assert_contains "and is labelled as being outside a test rather than folded in with them" \
  "${OUT}" "outside any test"

# A comment asserting the old rule is as misleading to the next reader as an assertion is, so it is
# reported. Over-reporting costs a line; under-reporting is the defect this exists for.
assert_contains "a comment naming the rule is reported too" "${OUT}" "somethingElseEntirely"

assert_not_contains "a file naming nothing of interest is left out entirely" \
  "${OUT}" "SomethingUnrelatedTests"

# --- nothing found is its own outcome, never a pass --------------------------------------------------
#
# The commonest cause is a symbol spelled differently in the tests than in the app, and a reversal
# implemented against an empty list is one nothing was checked for (L98).
MISSING="$("${FIND}" aSymbolNothingNames 2>&1)"; MISSING_STATUS=$?
assert_equals "no test naming the symbol exits 1, not 0" "1" "${MISSING_STATUS}"
assert_contains "and says so in words rather than printing an empty list" \
  "${MISSING}" "NO test in the Swift test targets names"

# --- several symbols at once, because a decision is rarely about one name ----------------------------
BOTH="$("${FIND}" isAwaitingNudge namesNothingOfInterest 2>&1)"
assert_contains "the first symbol's tests are listed" "${BOTH}" "aShowStillAheadKeepsItsNudge"
assert_contains "and the second symbol's" "${BOTH}" "namesNothingOfInterest"
assert_contains "and each line says WHICH symbol it matched" "${BOTH}" "(isAwaitingNudge)"

# --- roots that are not there are unmeasured, not clean ----------------------------------------------
GONE="$(OVERTURE_TEST_ROOTS="${WORK}/nowhere" "${FIND}" isAwaitingNudge 2>&1)"; GONE_STATUS=$?
assert_equals "a root that does not exist exits 2" "2" "${GONE_STATUS}"
assert_contains "and says nothing was measured" "${GONE}" "Nothing was measured"

# --- the default roots survive a path with a space in it ---------------------------------------------
#
# This repository's own checkout lives under "Photography Assets". The first version of this script held
# its default roots in one space separated STRING and split on whitespace, which turned each root into
# three directories that do not exist, found nothing, and reported that in the same words a real empty
# result gets. It is asserted on the SOURCE because the default cannot be driven from here: overriding it
# is what the environment variable does, and doing that is precisely what would hide the bug.
SRC="$(cat "${FIND}")"
assert_contains "the default roots are an array" "${SRC}" "ROOT_LIST=("
assert_not_contains "and the old split-on-whitespace form is gone" "${SRC}" 'for root in ${ROOTS}'
# The assertion above is not enough on its own, and a mutation proved it: dropping the quotes from
# `"${ROOT_LIST[@]}"` reintroduces the identical splitting while leaving both the array and the absence
# of the old form intact, and every behavioural test above overrides the roots with a space free temp
# path, so nothing went red. This is the line that catches it.
assert_contains "and the array is always expanded QUOTED, which is what stops it splitting again" \
  "${SRC}" 'for root in "${ROOT_LIST[@]}"'

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "find-tests-naming.test.sh: all assertions passed"
  exit 0
else
  echo "find-tests-naming.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
