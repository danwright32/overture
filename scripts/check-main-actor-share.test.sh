#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary (#2501): assert_contains takes desc, haystack, needle.
# shellcheck source=./lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0
# shellcheck source=./check-main-actor-share.sh
source "${SCRIPT_DIR}/check-main-actor-share.sh"

# --- what it counts ------------------------------------------------------------------------------
#
# Both spellings are in this tree: `@MainActor` above the `@Suite` line and between it and the type. A
# reader of one of them reports about half the real number, and half is the answer that reads as a
# measurement (L11).
WORK="$(fixture_scratch_dir)"
# One scratch root for the whole file, removed at the end: the fixture runner fails a fixture that
# leaves anything behind, and every path below hangs off this one.
mkdir -p "${WORK}/mac/OvertureTests"

cat > "${WORK}/mac/OvertureTests/AboveTests.swift" <<'SWIFT'
import Testing

@MainActor
@Suite("Attribute above the suite line")
struct AboveTests {
    @Test func a() {}
}
SWIFT

cat > "${WORK}/mac/OvertureTests/BelowTests.swift" <<'SWIFT'
import Testing

@Suite("Attribute below the suite line")
@MainActor
struct BelowTests {
    @Test func b() {}
}
SWIFT

cat > "${WORK}/mac/OvertureTests/PlainTests.swift" <<'SWIFT'
import Testing

@Suite("No main actor at all")
struct PlainTests {
    @Test func c() {}

    // A helper isolated to the main actor does NOT isolate the tests, so counting this would report a
    // suite that queues when it does not.
    @MainActor
    private final class Helper {}
}
SWIFT

assert_equals "both spellings are counted, and a nested helper's attribute is not" \
  "3 2" "$(main_actor_counts "${WORK}/mac/OvertureTests")"

# --- what it says --------------------------------------------------------------------------------

assert_contains "the share is reported as a count and a percentage" \
  "$(main_actor_report 100 42 "")" "42 of 100 suites are @MainActor (42%)"

assert_contains "a share that has climbed says so, and says what it costs" \
  "$(main_actor_report 100 42 30)" "Up from 30%, so the parallel-testing queue got longer"

assert_contains "a share that has fallen says so" \
  "$(main_actor_report 100 42 50)" "Down from 50%"

UNCHANGED="$(main_actor_report 100 42 42)"
assert_not_contains "an unchanged share claims no direction of travel" "${UNCHANGED}" "Up from"
assert_not_contains "and none the other way either" "${UNCHANGED}" "Down from"

# --- the outcome that must never read as the clean one -------------------------------------------
#
# A tree where no suite could be read and a tree with no main-actor suites leave the same empty result,
# so the first has to say it measured nothing rather than report a comfortable 0% (L98, L11).
UNMEASURED="$(main_actor_report 0 0 "")"
UNMEASURED_STATUS=$?
assert_contains "a run that read no suite at all says it is UNMEASURED" "${UNMEASURED}" "UNMEASURED"
assert_equals "and says so in its exit code, which is what a caller reads" "2" "${UNMEASURED_STATUS}"
assert_not_contains "and never reports a percentage it did not measure" "${UNMEASURED}" "%"

# And the record is not stamped by such a run, or the last real measurement would be overwritten by one
# that read nothing and the direction of travel would be nonsense from then on.
RECORD_PROBE="${WORK}/record-probe"
printf '%s\n' "37" > "${RECORD_PROBE}"
OVERTURE_MAIN_ACTOR_RECORD="${RECORD_PROBE}" REPO_ROOT_OVERRIDE="${WORK}/nowhere" \
  main_actor_share_main > /dev/null 2>&1
assert_equals "an unmeasured run leaves the last real reading alone" \
  "37" "$(tr -d ' \n' < "${RECORD_PROBE}")"

# A machine that has never run this before has no record, which is every fresh clone. It must say
# nothing about a direction of travel and, more to the point, print no error of its own: an input
# redirection is processed before the `2>/dev/null` meant to quieten it, so the first version announced
# a missing file on every first run.
ABSENT_RECORD="${WORK}/never-written"
FIRST_RUN_ERRORS="$(OVERTURE_MAIN_ACTOR_RECORD="${ABSENT_RECORD}" REPO_ROOT_OVERRIDE="${WORK}" \
  main_actor_share_main 2>&1 >/dev/null)"
assert_empty "the first run on a machine with no record says nothing on stderr" "${FIRST_RUN_ERRORS}"

FIRST_RUN="$(OVERTURE_MAIN_ACTOR_RECORD="${ABSENT_RECORD}.2" REPO_ROOT_OVERRIDE="${WORK}" main_actor_share_main 2>/dev/null)"
assert_not_contains "and claims no direction of travel it has nothing to compare against" \
  "${FIRST_RUN}" "Up from"

# The other direction, so the line above cannot pass by nothing ever being written (L3).
OVERTURE_MAIN_ACTOR_RECORD="${RECORD_PROBE}" REPO_ROOT_OVERRIDE="${WORK}" main_actor_share_main > /dev/null 2>&1
assert_not_equals_37="$(tr -d ' \n' < "${RECORD_PROBE}")"
assert_equals "while a run that really measured records what it saw" \
  "66" "${assert_not_equals_37}"

rm -rf "${WORK}"

if [ "${FAILURES:-0}" -ne 0 ]; then
  echo "${FAILURES} check-main-actor-share failure(s)"
  exit 1
fi
echo "all check-main-actor-share checks passed"
