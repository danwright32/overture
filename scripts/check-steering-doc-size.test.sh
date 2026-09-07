#!/usr/bin/env bash
# Fixture for scripts/check-steering-doc-size.sh (#3640).
#
# The subject reads files that steer every session, so the fixture points it at a throwaway tree
# instead: left real it would assert about whatever AGENTS.md happens to weigh on the day somebody
# runs it, and the interesting cases (over the threshold, unreadable) cannot be produced at all
# without writing to the real one (L2).
set -uo pipefail
# #3481/L372: captured BEFORE the cd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.." || exit 1

# shellcheck source=./lib/shell-assertions.sh
. "${SCRIPT_DIR}/lib/shell-assertions.sh"

FAILURES=0
SCRIPT="$(pwd)/scripts/check-steering-doc-size.sh"

WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${WORK}"' EXIT

# A tree with a CLAUDE.md importing one file of a chosen size.
make_tree() {
  local dir="$1" bytes="$2"
  rm -rf "${dir}"; mkdir -p "${dir}"
  printf '@AGENTS.md\n' > "${dir}/CLAUDE.md"
  head -c "${bytes}" /dev/zero | tr '\0' 'x' > "${dir}/AGENTS.md"
}

run_on() {
  OVERTURE_STEERING_ROOT="$1" OVERTURE_STEERING_LIMIT="${2:-1000}" \
    OVERTURE_STEERING_WARN_AT="${3:-800}" "${SCRIPT}" 2>&1
}
status_of() {
  local out; out="$(run_on "$@")"; local rc=$?
  printf '%s' "${out}" > "${WORK}/last-output"
  return "${rc}"
}

# 1. Comfortably under the threshold: in step, and it SAYS the number, because a check that reports
#    only a verdict cannot be re-judged later (L316).
make_tree "${WORK}/small" 100
status_of "${WORK}/small"; rc=$?
assert_equals "a small doc is in step (exit 0)" "0" "${rc}"
assert_contains "it names the file it measured" "$(cat "${WORK}/last-output")" "AGENTS.md"
assert_contains "it states the size it measured" "$(cat "${WORK}/last-output")" "100"

# 2. Past the warning threshold but under the limit: ADVISORY. Exit 1 so a caller can tell, and the
#    caller is what decides whether it blocks (it does not).
make_tree "${WORK}/warn" 900
status_of "${WORK}/warn"; rc=$?
assert_equals "a doc past the warning threshold reports (exit 1)" "1" "${rc}"
assert_contains "it names the file that is close" "$(cat "${WORK}/last-output")" "AGENTS.md"
assert_contains "it names the limit it is close to" "$(cat "${WORK}/last-output")" "1000"

# 3. Past the limit itself. Still exit 1 (it is the same action: split it), but the wording has to
#    differ, because "getting close" and "already over" call for different urgency (L11).
make_tree "${WORK}/over" 1200
status_of "${WORK}/over"; rc=$?
assert_equals "a doc over the limit reports (exit 1)" "1" "${rc}"
assert_contains "it says it is already over" "$(cat "${WORK}/last-output")" "OVER"

# 4. UNMEASURED, and never folded into either of the others. A tree with no CLAUDE.md at all and a
#    tree whose docs are all comfortably small leave the same empty result, and the emptiest possible
#    failure must not read as the cleanest possible pass (L98, L11).
rm -rf "${WORK}/none"; mkdir -p "${WORK}/none"
status_of "${WORK}/none"; rc=$?
assert_equals "no CLAUDE.md at all is UNMEASURED (exit 2)" "2" "${rc}"
assert_contains "and says so in that word" "$(cat "${WORK}/last-output")" "UNMEASURED"

# 5. An import naming a file that is not there is UNMEASURED, never a clean pass on CLAUDE.md alone.
#    This is the case that hides: CLAUDE.md is 11 bytes here, so measuring it and stopping would
#    report the healthiest possible number for a session whose rules did not load at all.
rm -rf "${WORK}/broken"; mkdir -p "${WORK}/broken"
printf '@AGENTS.md\n' > "${WORK}/broken/CLAUDE.md"
status_of "${WORK}/broken"; rc=$?
assert_equals "an import that resolves to nothing is UNMEASURED (exit 2)" "2" "${rc}"
# The needle is the whole PHRASE, not the filename: "AGENTS.md" alone also appears in the ordinary
# measurement line, so a bare filename assertion is answered by a line that is not the refusal and
# passes while the refusal is gone (L135). Found by mutating the refusal away and watching this
# assertion stay green.
assert_contains "and names the import it could not follow" \
  "$(cat "${WORK}/last-output")" "imports AGENTS.md"

# 6. It FOLLOWS the import rather than measuring only the file it was pointed at. Without this the
#    check would pass forever on this repo, whose CLAUDE.md is one line long.
make_tree "${WORK}/follow" 900
status_of "${WORK}/follow"; rc=$?
assert_equals "the imported file is what gets measured (exit 1)" "1" "${rc}"
# It reports a line per file in the graph, which is right, so the claim to assert is that the
# IMPORTED file's size is among them: a check that stopped at CLAUDE.md would print its 11
# characters, call the tree healthy, and never see the file that actually loads.
assert_contains "and the imported file's own size is reported" \
  "$(cat "${WORK}/last-output")" "AGENTS.md is 900 characters"

if [ "${FAILURES}" -eq 0 ]; then
  echo "check-steering-doc-size.test.sh: all assertions passed"
else
  echo "check-steering-doc-size.test.sh: ${FAILURES} assertion(s) failed"
fi
exit $(( FAILURES > 0 ? 1 : 0 ))
