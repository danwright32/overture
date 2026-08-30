#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501).
# shellcheck source=../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/shell-assertions.sh"

# Pure-function coverage for check-fixtures-do-not-age.sh (#2669). The real check shifts every dated
# fixture in the repo and runs the whole Swift suite, which takes minutes and cannot ride in CI. This
# fixture drives the three pure functions against throwaway text instead, so it runs anywhere.
#
# The load-bearing cases are the shifter's two measured mistakes, both of which produced failures that
# were entirely its own doing before they were fixed:
#   - a date INSIDE a longer string (`"2026-08-06 14:00"`) must move too, or one end of a pair is left
#     behind and the mismatch that causes is reported as a year sensitivity;
#   - a year outside 1980..2100 must NOT move, because those are sentinels and format examples.
#
# And `declared_year_sensitive` on a missing or comment-only baseline must return empty rather than
# killing the script: it runs under `pipefail`, and the first real run of this check exited 1 having
# found six genuine failures and printed none of them, because a grep that matched nothing took the
# whole pipeline down.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./check-fixtures-do-not-age.sh
source "${SCRIPT_DIR}/check-fixtures-do-not-age.sh"
# The script's own `set -euo pipefail` is now active here too. Turn errexit off so one failing
# assertion does not abort the rest of the run.
set +e

FAILURES=0

# MARK: shift_dates

out="$(printf 'let d = "2026-07-01"\n' | shift_dates 3)"
assert_equals "a plain date moves by the given number of years" 'let d = "2029-07-01"' "${out}"

out="$(printf 'nightTimes: ["2026-08-06 14:00"]\n' | shift_dates 3)"
assert_equals "a date inside a longer string moves too" 'nightTimes: ["2029-08-06 14:00"]' "${out}"

out="$(printf 'let t = "2026-06-25T03:00:00Z"\n' | shift_dates 3)"
assert_equals "an ISO timestamp moves" 'let t = "2029-06-25T03:00:00Z"' "${out}"

out="$(printf 'a "2026-01-02" and "2026-03-04"\n' | shift_dates 3)"
assert_equals "two dates on one line both move" 'a "2029-01-02" and "2029-03-04"' "${out}"

out="$(printf 'let epoch = "1970-01-01"\n' | shift_dates 3)"
assert_equals "a year before 1980 is a sentinel and stays put" 'let epoch = "1970-01-01"' "${out}"

out="$(printf 'let far = "2199-05-05"\n' | shift_dates 3)"
assert_equals "a year past 2100 is a sentinel and stays put" 'let far = "2199-05-05"' "${out}"

out="$(printf 'let fmt = "%%Y-%%m-%%d"\n' | shift_dates 3)"
assert_equals "a format string is not a date" 'let fmt = "%Y-%m-%d"' "${out}"

out="$(printf 'no dates here at all\n' | shift_dates 3)"
assert_equals "a line with no date is passed through byte for byte" 'no dates here at all' "${out}"

# MARK: shift_epochs (#2994)

# A date written as a NUMBER is still a date, and the string shifter cannot see one. #2986 was exactly
# that defect and this check could not have found it.
out="$(printf 'let now = Date(timeIntervalSince1970: 1_754_400_000)\n' | shift_epochs 3)"
assert_equals "an epoch literal inside the window moves" \
  'let now = Date(timeIntervalSince1970: 1849094400)' "${out}"

# The shift is CALENDAR arithmetic, not a fixed number of seconds, so an epoch literal and a dated string
# in the same test land on the same day. 1754400000 is 2025-08-05 13:20 UTC; 1849094400 is 2028-08-05
# 13:20 UTC. Adding 3 * 365.25 days would miss by a day and the mismatch would be reported as a year
# sensitivity the shifter itself caused, which is the mistake shift_dates' own header records making.
assert_equals "and lands on the same calendar day three years on" "2028-08-05T13:20:00" \
  "$(python3 -c 'import datetime; print(datetime.datetime.fromtimestamp(1849094400, datetime.UTC).strftime("%Y-%m-%dT%H:%M:%S"))')"

# The overwhelming majority of these literals are arbitrary instants chosen because a test needed two
# moments in an order. Moving those would change the thing rather than move the clock. Measured
# 2026-08-21: 283 test files carry one and most are of this shape.
out="$(printf 'let a = Date(timeIntervalSince1970: 0)\n' | shift_epochs 3)"
assert_equals "a zero epoch is an arbitrary instant and stays put" \
  'let a = Date(timeIntervalSince1970: 0)' "${out}"

out="$(printf 'let b = Date(timeIntervalSince1970: 9_999)\n' | shift_epochs 3)"
assert_equals "a small epoch stays put" 'let b = Date(timeIntervalSince1970: 9_999)' "${out}"

out="$(printf 'x Date(timeIntervalSince1970: 1_000_000_000) y Date(timeIntervalSince1970: 1_100_000_000)\n' | shift_epochs 3)"
assert_contains "two epochs on one line both move" "${out}" "1094694400"
assert_contains "and the second one too" "${out}" "1194608000"

out="$(printf 'no epoch here\n' | shift_epochs 3)"
assert_equals "a line with no epoch is passed through byte for byte" 'no epoch here' "${out}"

# The two shifters compose, which is the point: a test pairing a dated string with an epoch literal has
# BOTH ends moved. Moving one end is the mistake the date shifter already made once.
out="$(printf 'let d = "2026-07-01"; let n = Date(timeIntervalSince1970: 1_754_400_000)\n' \
        | shift_dates 3 | shift_epochs 3)"
assert_contains "the string end moves" "${out}" '"2029-07-01"'
assert_contains "and the epoch end moves in the same pass" "${out}" "1849094400"

# MARK: live_store_tests_with_a_pinned_clock (#2994)

# Reported, never shifted, because there is nothing to shift: the data comes from the live store, which
# no rewrite of mac/ can touch, so the other side of every comparison moves on its own every day.
PINWORK="$(fixture_scratch_dir)"
mkdir -p "${PINWORK}/mac/OvertureTests" "${PINWORK}/mac/OvertureHostedTests"
cat > "${PINWORK}/mac/OvertureTests/PinnedLiveTests.swift" <<'SWIFT'
struct PinnedLiveTests {
    @Test func readsTheStoreWithAFrozenClock() {
        let copy = try LiveStoreClone.makeClone(in: dir)
        let now = Date(timeIntervalSince1970: 1_754_400_000)
    }
    @Test func anOrdinaryTestInTheSameFile() {
        let x = 1
    }
}
SWIFT
cat > "${PINWORK}/mac/OvertureTests/NoStoreTests.swift" <<'SWIFT'
struct NoStoreTests {
    @Test func pinsAClockButNeverReadsTheStore() {
        let now = Date(timeIntervalSince1970: 1_754_400_000)
    }
}
SWIFT
OUT="$(REPO_ROOT="${PINWORK}" live_store_tests_with_a_pinned_clock)"
assert_contains "a live-store test with a pinned clock is named" "${OUT}" "readsTheStoreWithAFrozenClock"
# Named per TEST, not per file: a live-store suite holds ordinary tests too, and sending the reader to
# functions with nothing to do with the store is how an advisory gets ignored (L36).
assert_not_contains "an ordinary test in the same file is not named" "${OUT}" "anOrdinaryTestInTheSameFile"
# And a pinned clock with no live store is somebody else's problem: the shifter can see that one.
assert_not_contains "a pinned clock outside a live-store file is not named" "${OUT}" "pinsAClockButNeverReadsTheStore"

# A clock pinned as a SUITE PROPERTY, which is the commonest way this is written here, pins every test in
# the suite. Attributing it to whichever test happens to come first would name the wrong one, so it is
# reported as the suite.
cat > "${PINWORK}/mac/OvertureTests/SuitePinnedTests.swift" <<'SWIFT'
struct SuitePinnedTests {
    private let now = Date(timeIntervalSince1970: 1_754_400_000)
    let copy = try LiveStoreClone.makeClone(in: dir)
    @Test func oneTest() { let x = 1 }
    @Test func anotherTest() { let y = 2 }
}
SWIFT
OUT="$(REPO_ROOT="${PINWORK}" live_store_tests_with_a_pinned_clock)"
assert_contains "a suite-level pinned clock is reported" "${OUT}" "the whole suite"
assert_not_contains "and is not blamed on the first test" "${OUT}" "SuitePinnedTests.swift: oneTest"
rm -f "${PINWORK}/mac/OvertureTests/SuitePinnedTests.swift"

# A tree with no such test reports nothing, so the check does not accuse by default (L1's other half).
rm -f "${PINWORK}/mac/OvertureTests/PinnedLiveTests.swift"
assert_empty "a tree with no pinned live-store test reports nothing" \
  "$(REPO_ROOT="${PINWORK}" live_store_tests_with_a_pinned_clock)"
rm -rf "${PINWORK}"

# MARK: failing_test_names

log="$(fixture_scratch_file)"
cat > "${log}" <<'LOG'
some build noise
Failing tests:
	GroupingTests.groupsByDateWithWeekday()
	QueueModelTests.rowsGroupByDateWithUndatedLast()
	GroupingTests.groupsByDateWithWeekday()

** TEST FAILED **
LOG
out="$(failing_test_names < "${log}")"
assert_equals "the failing block is read, de-suited, de-duplicated and sorted" \
  "$(printf 'groupsByDateWithWeekday\nrowsGroupByDateWithUndatedLast')" "${out}"

cat > "${log}" <<'LOG'
everything passed
** TEST SUCCEEDED **
LOG
out="$(failing_test_names < "${log}")"
assert_empty "a clean log names no failing test" "${out}"
rm -f "${log}"

# MARK: declared_year_sensitive

baseline="$(fixture_scratch_file)"
cat > "${baseline}" <<'BASE'
# a comment line
#
bTest
aTest
aTest
BASE
out="$(declared_year_sensitive "${baseline}")"
assert_equals "the baseline drops comments and blanks, de-duplicates and sorts" \
  "$(printf 'aTest\nbTest')" "${out}"

cat > "${baseline}" <<'BASE'
# nothing but a header
BASE
out="$(declared_year_sensitive "${baseline}")"
assert_empty "a comment-only baseline reads as empty rather than failing the pipeline" "${out}"

out="$(declared_year_sensitive "${baseline}.does-not-exist")"
assert_empty "a missing baseline reads as empty rather than killing the script" "${out}"
rm -f "${baseline}"

# MARK: the real baseline is readable by the real reader

real="$(declared_year_sensitive)"
if [[ -z "${real}" ]]; then
  fail "the checked-in baseline reads as empty, so the real check would compare against nothing"
else
  pass "the checked-in baseline reads back $(printf '%s\n' "${real}" | wc -l | tr -d ' ') test names"
fi

if [[ ${FAILURES} -gt 0 ]]; then
  echo "check-fixtures-do-not-age.test.sh: ${FAILURES} failed"
  exit 1
fi
echo "check-fixtures-do-not-age.test.sh: all passed"
