#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=./lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"

# #4338 (A10): the reader of `LandingRun.entryFlushSaves`. What it must never do is read a store that records no
# flush count as a rate of zero, or a window with no landings as one (L90, L98). Driven against small stores
# this fixture builds with sqlite3, never the live one (L2).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/landing-flush-rate.sh"

FAILURES=0
WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${WORK}"' EXIT

# Core Data's clock: seconds since 2001-01-01.
NOW=$(( $(date +%s) - 978307200 ))
DAY=86400

run_script() {
  local out code
  out="$("${SCRIPT}" "$@" 2>&1)"
  code=$?
  printf '%s\nexit=%s\n' "${out}" "${code}"
}

# A store whose landing records carry the count: four this fortnight (one saved once, one twice), one older
# than the window, and one with no start time (a record from before landings recorded one).
COUNTED="${WORK}/counted.store"
sqlite3 "${COUNTED}" "CREATE TABLE ZLANDINGRUN (Z_PK INTEGER PRIMARY KEY, ZRUNIDENTITY VARCHAR, ZSTARTEDAT TIMESTAMP, ZENTRYFLUSHSAVES INTEGER);
INSERT INTO ZLANDINGRUN (ZRUNIDENTITY, ZSTARTEDAT, ZENTRYFLUSHSAVES) VALUES
 ('a', $(( NOW - 1 * DAY )), 0), ('b', $(( NOW - 2 * DAY )), 1), ('c', $(( NOW - 3 * DAY )), 2),
 ('d', $(( NOW - 4 * DAY )), 0), ('old', $(( NOW - 40 * DAY )), 2), ('a7', NULL, 0);"

COUNTED_RUN="$(run_script --store "${COUNTED}")"
assert_contains "the window counts only landings started in it" "${COUNTED_RUN}" "landings started in the last 14 days: 4"
assert_contains "and gives the share that saved first, with once and twice apart" "${COUNTED_RUN}" \
  "saved pending edits first: 2 of 4 (50%), once 1, twice 1, 3 entry flush saves in all"
assert_contains "and exits 0" "${COUNTED_RUN}" "exit=0"

WIDE_RUN="$(run_script --store "${COUNTED}" --days 60)"
assert_contains "a wider window reaches the older landing, never the one with no start time" "${WIDE_RUN}" \
  "landings started in the last 60 days: 5"

# A store from before #4338: no column, so no rate, never zero.
BEFORE="${WORK}/before.store"
sqlite3 "${BEFORE}" "CREATE TABLE ZLANDINGRUN (Z_PK INTEGER PRIMARY KEY, ZRUNIDENTITY VARCHAR, ZSTARTEDAT TIMESTAMP);
INSERT INTO ZLANDINGRUN (ZRUNIDENTITY, ZSTARTEDAT) VALUES ('a', $(( NOW - DAY )));"
BEFORE_RUN="$(run_script --store "${BEFORE}")"
assert_contains "a store with no flush count is unmeasured" "${BEFORE_RUN}" "UNMEASURED: this store records no entry flush count"
assert_contains "and exits 2" "${BEFORE_RUN}" "exit=2"
assert_not_contains "and never prints a rate" "${BEFORE_RUN}" "saved pending edits first"

# A window holding no landing says so, with no rate.
QUIET="${WORK}/quiet.store"
sqlite3 "${QUIET}" "CREATE TABLE ZLANDINGRUN (Z_PK INTEGER PRIMARY KEY, ZSTARTEDAT TIMESTAMP, ZENTRYFLUSHSAVES INTEGER);
INSERT INTO ZLANDINGRUN (ZSTARTEDAT, ZENTRYFLUSHSAVES) VALUES ($(( NOW - 30 * DAY )), 1);"
QUIET_RUN="$(run_script --store "${QUIET}")"
assert_contains "an empty window says there is no rate" "${QUIET_RUN}" "No landing started in the last 14 days, so there is no rate to give."
assert_not_contains "rather than a share of nothing" "${QUIET_RUN}" "saved pending edits first"

# A file that is not a store is unmeasured, and no store at all is its own answer.
BROKEN="${WORK}/broken.store"
echo "not a database" > "${BROKEN}"
BROKEN_RUN="$(run_script --store "${BROKEN}")"
assert_contains "an unreadable store is unmeasured" "${BROKEN_RUN}" "UNMEASURED"
assert_contains "and exits 2" "${BROKEN_RUN}" "exit=2"

MISSING_RUN="$(run_script --store "${WORK}/nothing-here.store")"
assert_contains "no store is said as such" "${MISSING_RUN}" "NO STORE at"
assert_contains "and exits 3, apart from unmeasured" "${MISSING_RUN}" "exit=3"

# The live store is read as a copy: the store this fixture names is left byte for byte as it was.
BEFORE_SUM="$(shasum "${COUNTED}")"
run_script --store "${COUNTED}" >/dev/null
assert_equals "the store read is never written" "${BEFORE_SUM}" "$(shasum "${COUNTED}")"

BAD_DAYS="$(run_script --store "${COUNTED}" --days soon)"
assert_contains "a window that is not a number is refused" "${BAD_DAYS}" "exit=64"

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "All landing-flush-rate.sh fixtures passed."
