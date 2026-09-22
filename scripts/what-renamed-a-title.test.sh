#!/usr/bin/env bash
# Fixture for scripts/what-renamed-a-title.sh (#4147).
#
# Every case builds its own throwaway ledger rather than reading the real one: a fixture pointed at
# ~/Library/Application Support would assert about whatever this Mac's scout runs happen to have
# recorded, and that file is a record of Dan's own data (L2).
set -uo pipefail
# #3481/L372: captured BEFORE the cd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.." || exit 1

# shellcheck source=./lib/shell-assertions.sh
. "${SCRIPT_DIR}/lib/shell-assertions.sh"

FAILURES=0
SCRIPT="$(pwd)/scripts/what-renamed-a-title.sh"

WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${WORK}"' EXIT

LEDGER="${WORK}/title-renames.json"
cat > "${LEDGER}" <<'JSON'
{
  "entries" : [
    {
      "arm" : "stableSource",
      "at" : "2026-09-19T14:02:11Z",
      "from" : "Back to Shakespeare",
      "key" : "marlise a new golden age musical|2026-09-04|the players theatre",
      "to" : "Marlise (A New Golden Age Musical)"
    },
    {
      "arm" : "anyRunURL",
      "at" : "2026-09-20T09:15:00Z",
      "from" : "Blues For Greeny",
      "key" : "blues for greeny the music of peter green|2026-11-14|the cutting room",
      "to" : "Blues For Greeny (The Music of Peter Green)"
    }
  ]
}
JSON

# THE THREE OUTCOMES, and they are the point of the script: an empty answer means three different
# things and each has to be distinguishable from the others (L11, L98).

out="$("${SCRIPT}" --ledger "${LEDGER}" 2>&1)"; status=$?
assert_equals "a readable ledger exits 0" "0" "${status}"
assert_contains "it says how many it holds" "${out}" "2 rename(s) recorded"
assert_contains "it names the arm that did each rename" "${out}" "stableSource"
assert_contains "it names the title that was replaced" "${out}" "was: Back to Shakespeare"

out="$("${SCRIPT}" --ledger "${LEDGER}" --match "greeny" 2>&1)"; status=$?
assert_equals "a match that finds something exits 0" "0" "${status}"
assert_contains "a match narrows to the entries that match" "${out}" "showing 1"
assert_not_contains "and leaves out the ones that do not" "${out}" "Back to Shakespeare"

out="$("${SCRIPT}" --ledger "${LEDGER}" --match "nothing-like-this" 2>&1)"; status=$?
assert_equals "a match that finds nothing is still a reading" "0" "${status}"
assert_contains "and says so as a measurement of zero" "${out}" "NO RENAMES"

out="$("${SCRIPT}" --ledger "${WORK}/not-there.json" 2>&1)"; status=$?
assert_equals "no ledger at all is its own exit code" "3" "${status}"
assert_contains "and says nothing is known either way" "${out}" "NO LEDGER"

printf 'not json' > "${WORK}/broken.json"
out="$("${SCRIPT}" --ledger "${WORK}/broken.json" 2>&1)"; status=$?
assert_equals "a ledger that is there and cannot be read is UNMEASURED" "2" "${status}"
assert_contains "and says so rather than reading as empty" "${out}" "UNMEASURED"

if [ "${FAILURES}" -eq 0 ]; then
  echo "what-renamed-a-title.test.sh: all assertions passed"
  exit 0
fi
echo "what-renamed-a-title.test.sh: ${FAILURES} assertion(s) failed"
exit 1
