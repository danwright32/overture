#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501).
# shellcheck source=./lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"

# #3640: the wiring for the always-loaded size advisory. AGENTS.md crossed the 150,000 character
# ceiling on 2026-09-06 and nothing in this repository could have said so; what reported it was a
# warning Dan happened to have on screen. The rules do not fail past that ceiling, they stop
# ARRIVING, and a rule that never arrived is indistinguishable from one that was followed (L429).
#
# Driven against a THROWAWAY directory, never this checkout: a fixture reading the real AGENTS.md
# would assert about whatever that file happened to be that day and would go red for a reason
# unrelated to the code (L2).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${SCRIPT_DIR}/check-always-loaded-size.sh"

FAILURES=0

# Every scratch directory this fixture makes, removed on the way out. The runner fails a fixture that
# leaves any behind, and it is right to: one per run, forever, outside the checkout where nobody
# looks. A trap rather than a line at the end, so a fixture that dies mid way still tidies up.
# A FILE rather than a variable, because every caller reaches tracked_scratch_dir through a command
# substitution, which is a subshell: a variable set in there is gone by the time the parent reads it,
# and the fixture leaked its whole run's directories while looking exactly like it was tracking them.
SCRATCH_REGISTRY="$(fixture_scratch_file)"
cleanup_scratch() {
  local dir
  while IFS= read -r dir; do
    [[ -n "${dir}" ]] || continue
    # The unreadable-file case leaves a mode nothing can delete through.
    chmod -R u+rwX "${dir}" 2>/dev/null
    rm -rf "${dir}"
  done < "${SCRATCH_REGISTRY}"
  rm -f "${SCRATCH_REGISTRY}"
}
trap cleanup_scratch EXIT

tracked_scratch_dir() {
  local dir
  dir="$(fixture_scratch_dir)"
  echo "${dir}" >> "${SCRATCH_REGISTRY}"
  echo "${dir}"
}

# A directory holding an AGENTS.md of exactly <chars> characters, plus the one-line CLAUDE.md that
# imports it, which is what this repo really has.
make_root_with_agents_of() {
  local chars="$1" root
  root="$(tracked_scratch_dir)"
  printf '@AGENTS.md\n' > "${root}/CLAUDE.md"
  # head -c of /dev/zero would give NUL bytes, which wc -c counts and no editor would; 'x' keeps the
  # file something a person could actually have written.
  yes x | tr -d '\n' | head -c "${chars}" > "${root}/AGENTS.md"
  echo "${root}"
}

run_check() {
  local root="$1" limit="$2" out code
  out="$(ALWAYS_LOADED_REPO_ROOT="${root}" ALWAYS_LOADED_LIMIT="${limit}" "${CHECK}" 2>&1)"
  code=$?
  printf '%s\n--exit--%s' "${out}" "${code}"
}

# --- quiet well under the ceiling -------------------------------------------------------------
# The everyday state. A check that spoke on every run would be noise, and noise is what teaches
# somebody to skip the whole readout (L36).
result="$(run_check "$(make_root_with_agents_of 1000)" 150000)"
assert_not_contains "says nothing about a small AGENTS.md" "${result%$'\n'--exit--*}" "AGENTS.md"
assert_contains "exits 0 when everything is small" "${result}" "--exit--0"

# --- warns while there is still time to act ----------------------------------------------------
# The whole value is arriving BEFORE the crossing. At the threshold it has to speak, and it has to
# name the file and the numbers, because "something is getting big" is not something anybody can act
# on (L11, L80).
result="$(run_check "$(make_root_with_agents_of 125000)" 150000)"
assert_contains "names the file approaching the ceiling" "${result}" "AGENTS.md"
assert_contains "gives the size it measured" "${result}" "125000"
assert_contains "gives the ceiling it measured against" "${result}" "150000"
assert_contains "warning still exits 0" "${result}" "--exit--0"

# --- says plainly when the ceiling is already crossed ------------------------------------------
# Over is a different sentence from approaching, because the action is different: over, the rules
# may already not be arriving.
result="$(run_check "$(make_root_with_agents_of 151000)" 150000)"
assert_contains "says it is OVER the ceiling" "${result}" "OVER"
assert_contains "over the ceiling still exits 0, never blocking a push" "${result}" "--exit--0"

# --- an advisory can never fail a run ------------------------------------------------------------
# Same reasoning scripts/check-branch-backlog.sh already rides along under: a big instructions file
# is not a defect in the change being pushed, and a gate here would be overridden every time.
for size in 1000 125000 151000 400000; do
  result="$(run_check "$(make_root_with_agents_of "${size}")" 150000)"
  assert_contains "exits 0 at ${size} characters" "${result}" "--exit--0"
done

# --- nothing measured is its own answer, never a clean bill --------------------------------------
# An empty directory and a directory of small files leave the same silence, and the emptiest
# possible failure must not read as the cleanest possible pass (L98, L11).
empty_root="$(tracked_scratch_dir)"
result="$(run_check "${empty_root}" 150000)"
assert_contains "says UNMEASURED when it found no always-loaded file at all" "${result}" "UNMEASURED"
assert_contains "UNMEASURED still exits 0" "${result}" "--exit--0"

# --- a file that is present and unreadable is not a file of zero characters ----------------------
unreadable_root="$(make_root_with_agents_of 1000)"
chmod 000 "${unreadable_root}/AGENTS.md"
result="$(run_check "${unreadable_root}" 150000)"
chmod 644 "${unreadable_root}/AGENTS.md"
assert_contains "says it could not measure a file it could not read" "${result}" "could not measure"
assert_not_contains "does not report an unreadable file as 0 characters" "${result}" "0 characters"

# --- AGENTS.md is measured BY NAME, not only because CLAUDE.md happens to import it ---------------
# Found by mutation: dropping AGENTS.md from the script's roots left every assertion above green,
# because the fixture's CLAUDE.md imports it and the import following reached it anyway. Both routes
# are real and either one alone is a guard that cannot go red on half of what it covers (L1).
no_import_root="$(tracked_scratch_dir)"
printf 'a project note with no import line\n' > "${no_import_root}/CLAUDE.md"
yes x | tr -d '\n' | head -c 151000 > "${no_import_root}/AGENTS.md"
result="$(run_check "${no_import_root}" 150000)"
assert_contains "measures AGENTS.md even when nothing imports it" "${result}" "AGENTS.md"
assert_contains "and still says it is over the ceiling" "${result}" "OVER"

# --- an imported file is always-loaded too, and shares the ceiling --------------------------------
# The mirror of the case above: a file reached ONLY through an @import carries exactly the same risk
# as one loaded by name, so the corpus follows imports rather than stopping at the two roots.
import_root="$(tracked_scratch_dir)"
printf '@docs/agents/testing.md\n' > "${import_root}/CLAUDE.md"
printf 'small\n' > "${import_root}/AGENTS.md"
mkdir -p "${import_root}/docs/agents"
yes x | tr -d '\n' | head -c 151000 > "${import_root}/docs/agents/testing.md"
result="$(run_check "${import_root}" 150000)"
assert_contains "names an imported file that is over the ceiling" "${result}" "docs/agents/testing.md"

# --- it measures every always-loaded file, not only AGENTS.md ------------------------------------
# The class, not the instance (L30). CLAUDE.md is loaded the same way and has the same ceiling; it
# is one line today and nothing says it stays that way.
both_root="$(make_root_with_agents_of 1000)"
yes y | tr -d '\n' | head -c 140000 > "${both_root}/CLAUDE.md"
result="$(run_check "${both_root}" 150000)"
assert_contains "names CLAUDE.md when that is the file getting big" "${result}" "CLAUDE.md"

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "check-always-loaded-size.test.sh: all assertions passed"
else
  echo "check-always-loaded-size.test.sh: ${FAILURES} failure(s)"
  exit 1
fi
