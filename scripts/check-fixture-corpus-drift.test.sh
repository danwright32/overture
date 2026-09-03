#!/usr/bin/env bash
# Fixture for scripts/check-fixture-corpus-drift.sh (#3426).
#
# Every collaborator that reaches outside is a seam and each is set here: the live store it reads, and
# the tree it scans for declarations. Left real, this fixture would assert about whatever Dan's store
# happens to hold on the day somebody runs it (L2, L224).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=./lib/shell-assertions.sh
. "$(dirname "$0")/lib/shell-assertions.sh"

FAILURES=0
SCRIPT="$(pwd)/scripts/check-fixture-corpus-drift.sh"

WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${WORK}"' EXIT

# A throwaway store with the tables and columns the real one has, holding a known number of rows.
make_store() {
  local path="$1" prospects="$2" presenters="$3"
  rm -f "${path}"
  sqlite3 "${path}" "create table ZPROSPECT (Z_PK integer primary key, ZPRESENTER text, ZVENUE text,
                     ZGROUPNAME text, ZSTATUSRAW text);
                     create table ZWATCHEDSOURCE (Z_PK integer primary key);"
  local i=0
  while [ "${i}" -lt "${prospects}" ]; do
    sqlite3 "${path}" "insert into ZPROSPECT (ZPRESENTER, ZVENUE, ZGROUPNAME, ZSTATUSRAW)
                       values ('p$((i % presenters))', 'v$((i % 4))', 'g${i}', 'new');"
    i=$((i + 1))
  done
}

# A tree holding one Swift file that declares a tagged live-shape number.
make_tree() {
  local dir="$1" dimension="$2" value="$3"
  mkdir -p "${dir}"
  cat > "${dir}/SomeCostTests.swift" <<SWIFT
@Suite("something")
struct SomeCostTests {
    // LIVE-SHAPE: ${dimension}
    private static let corpusSize = ${value}
}
SWIFT
}

run_check() {
  OVERTURE_LIVE_STORE="$1" OVERTURE_CORPUS_DECL_ROOT="$2" "${SCRIPT}" 2>&1
}

STORE="${WORK}/live.store"
make_store "${STORE}" 40 8

# --- 1. a declaration matching the live store passes ------------------------------------------------
TREE_OK="${WORK}/tree-ok"
make_tree "${TREE_OK}" prospects 40
RESULT="$(run_check "${STORE}" "${TREE_OK}")"
STATUS=$?
assert_equals "a declaration matching the live store exits 0" 0 "${STATUS}"
assert_contains "it says what it measured" "${RESULT}" "prospects"

# --- 2. a declaration that has fallen materially below is a FINDING, named ---------------------------
#
# The whole defect: the guard stays green while protecting a smaller world than the one that ships, and
# nothing says so. It must name WHICH dimension and BOTH numbers, not merely that the fixture is small.
TREE_STALE="${WORK}/tree-stale"
make_tree "${TREE_STALE}" prospects 20
RESULT="$(run_check "${STORE}" "${TREE_STALE}")"
STATUS=$?
assert_equals "a drifted declaration exits 1" 1 "${STATUS}"
assert_contains "it names the dimension" "${RESULT}" "prospects"
assert_contains "it names the declared figure" "${RESULT}" "20"
assert_contains "it names the live figure" "${RESULT}" "40"
assert_contains "it names the file" "${RESULT}" "SomeCostTests.swift"

# --- 3. a declaration slightly below is within tolerance and does not fire ---------------------------
#
# The store grows every night, so a guard firing on any difference at all fires on the ordinary case and
# is switched off within a day (L93). What it exists to catch is a fixture protecting a materially
# smaller world.
TREE_CLOSE="${WORK}/tree-close"
make_tree "${TREE_CLOSE}" prospects 39
RESULT="$(run_check "${STORE}" "${TREE_CLOSE}")"
STATUS=$?
assert_equals "one row below the live count is within tolerance" 0 "${STATUS}"

# --- 4. a declaration ABOVE the live count is not a finding ------------------------------------------
#
# A fixture larger than the live store exercises more than ships, which is the safe direction. Only
# falling BELOW hides a problem.
TREE_BIG="${WORK}/tree-big"
make_tree "${TREE_BIG}" prospects 400
RESULT="$(run_check "${STORE}" "${TREE_BIG}")"
STATUS=$?
assert_equals "a fixture larger than the live store exits 0" 0 "${STATUS}"

# --- 5. no live store at all is its own outcome, and NOT a failure ----------------------------------
#
# This is the ordinary state on a clone, in CI and in an agent worktree, so it can never be a refusal.
# It is also not a pass: a run that measured nothing must say so rather than reading as clean (L98).
RESULT="$(run_check "${WORK}/no-such-store" "${TREE_OK}")"
STATUS=$?
assert_equals "no live store exits 3" 3 "${STATUS}"
assert_contains "it says it measured nothing" "$(printf '%s' "${RESULT}" | tr 'A-Z' 'a-z')" "no live store"
assert_not_contains "a skip never reads as a pass" "${RESULT}" "within tolerance"

# --- 6. a store that is PRESENT and unreadable is a REFUSAL, not a skip ------------------------------
#
# The two are different: one is a machine that never had a store, the other is a measurement that failed.
# Folding them together makes the failed read look like a fresh clone (L11).
BROKEN="${WORK}/broken.store"
printf 'this is not a sqlite database\n' > "${BROKEN}"
RESULT="$(run_check "${BROKEN}" "${TREE_OK}")"
STATUS=$?
assert_equals "an unreadable store exits 2" 2 "${STATUS}"
assert_contains "an unreadable store says UNMEASURED" "${RESULT}" "UNMEASURED"

# --- 7. a tree declaring NOTHING is UNMEASURED, never clean -----------------------------------------
#
# A scan that found no declarations and a scan where every declaration is current leave the same empty
# result, and the emptiest possible failure must not read as the cleanest possible pass (L98).
EMPTY_TREE="${WORK}/tree-empty"
mkdir -p "${EMPTY_TREE}"
printf 'struct Nothing {}\n' > "${EMPTY_TREE}/Nothing.swift"
RESULT="$(run_check "${STORE}" "${EMPTY_TREE}")"
STATUS=$?
assert_equals "a tree declaring nothing exits 2" 2 "${STATUS}"
assert_contains "it says nothing was measured" "${RESULT}" "UNMEASURED"

# --- 8. an unknown dimension name is refused, not silently skipped -----------------------------------
#
# A tag naming a dimension the script cannot measure is a typo, and a typo that is silently ignored is a
# declaration nobody is checking while it reads as covered (L100).
TREE_TYPO="${WORK}/tree-typo"
make_tree "${TREE_TYPO}" prospcts 40
RESULT="$(run_check "${STORE}" "${TREE_TYPO}")"
STATUS=$?
assert_equals "an unknown dimension exits 2" 2 "${STATUS}"
assert_contains "it names the tag it could not measure" "${RESULT}" "prospcts"

# --- 9. it measures more than one dimension, and presenters is really counted ------------------------
TREE_TWO="${WORK}/tree-two"
mkdir -p "${TREE_TWO}"
cat > "${TREE_TWO}/TwoCostTests.swift" <<'SWIFT'
struct TwoCostTests {
    // LIVE-SHAPE: prospects
    static let prospects = 40
    // LIVE-SHAPE: presenters
    static let presenters = 2
}
SWIFT
RESULT="$(run_check "${STORE}" "${TREE_TWO}")"
STATUS=$?
assert_equals "a drifted second dimension exits 1" 1 "${STATUS}"
assert_contains "it names the drifted dimension" "${RESULT}" "presenters"

if [ "${FAILURES}" -eq 0 ]; then
  echo "All check-fixture-corpus-drift.sh fixtures passed."
else
  echo "${FAILURES} check-fixture-corpus-drift.sh assertion(s) failed."
  exit 1
fi
