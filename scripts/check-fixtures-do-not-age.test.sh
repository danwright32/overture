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

# MARK: failing_test_names

log="$(mktemp -t ageless-log)"
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

baseline="$(mktemp -t ageless-baseline)"
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
