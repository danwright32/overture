#!/usr/bin/env bash
set -uo pipefail

# #4328: the real-arm refusal, driven through the HOOK FILE ON THIS BRANCH rather than through whatever the
# primary checkout's core.hooksPath points at. Every worktree on this Mac runs the primary checkout's hook,
# so a push from an agent worktree before this merges would prove nothing about this code; invoking
# scripts/hooks/pre-push from this tree, the way git does (refs on stdin, remote name and URL as arguments,
# the pushing repository as the working directory), is what proves it.
#
# The pushing repository is a throwaway clone of a throwaway bare remote, so nothing here can reach GitHub.
# Its own pushes (to set up an existing remote branch) run with hooks switched off.
#
# The marker is BUILT here from two halves, as everywhere else, so this file holds no line that IS it.

# shellcheck source=./shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shell-assertions.sh"

FAILURES=0
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${LIB_DIR}/../.." && pwd)"
HOOK="${REPO_ROOT}/scripts/hooks/pre-push"
SCAN="${REPO_ROOT}/scripts/real-arm-scan.sh"
ZERO="0000000000000000000000000000000000000000"
MARKER="$(printf '%s%s' "OVERTURE-REAL-ARM" ": never commit")"

SCRATCH="$(fixture_scratch_dir)"
trap 'rm -rf "${SCRATCH}"' EXIT
REMOTE="${SCRATCH}/remote.git"
WORK="${SCRATCH}/work"

g() { git -C "${WORK}" -c core.hooksPath=/dev/null -c user.name=fixture -c user.email=fixture@example.invalid \
        -c commit.gpgsign=false "$@"; }

git init -q --bare "${REMOTE}"
git init -q "${WORK}"
g remote add origin "${REMOTE}"
g checkout -q -b main
echo "base" > "${WORK}/README"
g add README
g commit -q -m base
g push -q origin main

# Runs the hook from THIS tree as git would, from inside the pushing clone. Prints its output; its status is
# the subshell's.
run_hook() {
  local hook="$1" refs="$2"
  (cd "${WORK}" && printf '%s\n' "${refs}" | "${hook}" origin "${REMOTE}") 2>&1
}

# --- 1. a marked file added by one commit and deleted by the next is refused at push -------------------
g checkout -q -b leak main
printf '%s\n%s\n' "${MARKER}" "Prospect	0	groupName	sha256:00" > "${WORK}/real-arm-x1.oracle"
g add real-arm-x1.oracle
g commit -q -m "add a real-arm file"
LEAK_ADD="$(g rev-parse HEAD)"
g rm -q real-arm-x1.oracle
g commit -q -m "and delete it again"
LEAK_TIP="$(g rev-parse HEAD)"

out="$(run_hook "${HOOK}" "refs/heads/leak ${LEAK_TIP} refs/heads/leak ${ZERO}")"
status=$?
assert_equals "a branch whose first commit adds a real-arm file and second deletes it is refused" "1" "${status}"
assert_contains "and the refusal names the commit that added it" "${out}" "${LEAK_ADD} real-arm-x1.oracle"
assert_contains "and says it is a real-arm file" "${out}" "REFUSED: a commit in this push carries a real-arm file"

# The same history through CI's scan of a pull request's range, run as CI runs it: from inside the
# checkout being scanned.
out="$(cd "${WORK}" && "${SCAN}" "$(g rev-parse main)" "${LEAK_TIP}" 2>&1)"
status=$?
assert_equals "CI's scan refuses the same range" "1" "${status}"
assert_contains "and names the same commit" "${out}" "${LEAK_ADD} real-arm-x1.oracle"

# --- 2. an existing remote branch, updated with a leak --------------------------------------------------
g checkout -q -b topic main
echo "one" > "${WORK}/one.txt"
g add one.txt
g commit -q -m one
g push -q origin topic
TOPIC_REMOTE="$(g rev-parse HEAD)"
printf '%s\r\n%s\r\n' "${MARKER}" "written with CRLF" > "${WORK}/crlf.oracle"
g add crlf.oracle
g commit -q -m "a CRLF real-arm file"
CRLF_COMMIT="$(g rev-parse HEAD)"
out="$(run_hook "${HOOK}" "refs/heads/topic ${CRLF_COMMIT} refs/heads/topic ${TOPIC_REMOTE}")"
status=$?
assert_equals "an update to an existing remote branch carrying a real-arm file is refused" "1" "${status}"
assert_contains "and a marker line ending in a carriage return still counts" "${out}" "${CRLF_COMMIT} crlf.oracle"

# --- 3. the helper missing refuses by name ---------------------------------------------------------------
mkdir -p "${SCRATCH}/lonely/hooks"
cp "${HOOK}" "${SCRATCH}/lonely/hooks/pre-push"
out="$(run_hook "${SCRATCH}/lonely/hooks/pre-push" "refs/heads/main $(g rev-parse main) refs/heads/main $(g rev-parse main)")"
status=$?
assert_equals "with real-arm-guard.sh missing, even a clean push is refused" "1" "${status}"
assert_contains "and the refusal names the missing helper" "${out}" "real-arm-guard.sh is missing or unreadable"

# --- 4. the guard's own commit, and later edits to the probe and the plan's docs, push cleanly -----------
# The self-match case (L245, L673): every file that SPEAKS about the marker, copied from this tree as it
# is, plus a doc that quotes it inside a sentence and on a later line, and one whose first line is the
# marker with more after it.
g checkout -q -b guard main
mkdir -p "${WORK}/scripts/lib" "${WORK}/mac/OvertureTests" "${WORK}/docs"
for f in scripts/lib/real-arm-guard.sh scripts/lib/real-arm-guard.test.sh scripts/real-arm-scan.sh \
         scripts/hooks/pre-push scripts/landing-oracle.sh mac/OvertureTests/LandingOracle.swift \
         mac/OvertureTests/LandingOracleTests.swift mac/OvertureTests/LandingOracleCorpus.swift; do
  mkdir -p "${WORK}/$(dirname "${f}")"
  cp "${REPO_ROOT}/${f}" "${WORK}/${f}"
done
printf '%s\n%s\n%s\n' "# The plan" "A real-arm file begins with ${MARKER} and nothing else." "${MARKER}" \
  > "${WORK}/docs/plan.md"
printf '%s\n' "${MARKER} (a first line with more after it is not the marker)" > "${WORK}/docs/near-miss.txt"
g add -A
g commit -q -m "the guard's own commit"
echo "// a later edit to the probe" >> "${WORK}/mac/OvertureTests/LandingOracle.swift"
echo "A later edit to the plan." >> "${WORK}/docs/plan.md"
g add -A
g commit -q -m "later edits"
GUARD_TIP="$(g rev-parse HEAD)"
out="$(run_hook "${HOOK}" "refs/heads/guard ${GUARD_TIP} refs/heads/guard ${ZERO}")"
status=$?
assert_equals "the guard's own commit and later edits to the probe and docs push cleanly" "0" "${status}"
assert_not_contains "and nothing is refused" "${out}" "REFUSED"
out="$(cd "${WORK}" && "${SCAN}" "$(g rev-parse main)" "${GUARD_TIP}" 2>&1)"
assert_equals "and CI's scan of that range is clean" "0" "$?"

# --- 5. what the hook cannot read, it refuses (L42) ------------------------------------------------------
out="$(run_hook "${HOOK}" "refs/heads/ghost 1111111111111111111111111111111111111111 refs/heads/ghost ${ZERO}")"
status=$?
assert_equals "a pushed sha this clone cannot read is refused, not passed" "1" "${status}"
assert_contains "and the refusal says the commits could not be checked" "${out}" "could not be checked"

# --- 6. pushes that carry no commits are not refused -----------------------------------------------------
out="$(run_hook "${HOOK}" "refs/heads/leak ${ZERO} refs/heads/leak $(g rev-parse main)")"
assert_equals "a branch deletion carries no commits and passes" "0" "$?"
out="$(run_hook "${HOOK}" "refs/heads/topic ${TOPIC_REMOTE} refs/heads/topic ${TOPIC_REMOTE}")"
assert_equals "a push with nothing new in it passes" "0" "$?"

# --- 7. CI's scan refuses a range that selects nothing (L98) ---------------------------------------------
out="$(cd "${WORK}" && "${SCAN}" "$(g rev-parse main)" "$(g rev-parse main)" 2>&1)"
assert_equals "a range selecting no commits is unmeasured, not clean" "2" "$?"
assert_contains "and says so" "${out}" "UNMEASURED"

# --- 8. the tree scan, test-all.sh's second layer --------------------------------------------------------
g checkout -q guard
printf '%s\n' "${MARKER}" > "${WORK}/untracked.oracle"
out="$("${SCAN}" --tree "${WORK}" 2>&1)"
assert_equals "an untracked real-arm file in the tree is refused" "1" "$?"
assert_contains "and named" "${out}" "untracked.oracle"
rm -f "${WORK}/untracked.oracle"
out="$("${SCAN}" --tree "${WORK}" 2>&1)"
assert_equals "and with it gone the tree is clean, the self-matching files included" "0" "$?"

# --- 9. a tree the size of this repository --------------------------------------------------------------
# The scan first shipped reading each file through its own process substitution, and macOS bash 3.2 died
# part way through a tree of this repository's size (2,339 files on 2026-09-30, status 133), which the scan
# then reported as UNMEASURED on every merge gate run. Three thousand files, the marked one among them, is
# the real size; the handful above never reached it.
mkdir -p "${WORK}/many"
for i in $(seq 1 3000); do printf 'row %s\n' "${i}" > "${WORK}/many/f${i}.txt"; done
printf '%s\n' "${MARKER}" > "${WORK}/many/f1500.oracle"
out="$("${SCAN}" --tree "${WORK}" 2>&1)"
assert_equals "a real-arm file among three thousand is still refused, not unmeasured" "1" "$?"
assert_contains "and named" "${out}" "many/f1500.oracle"
rm -f "${WORK}/many/f1500.oracle"
out="$("${SCAN}" --tree "${WORK}" 2>&1)"
assert_equals "and three thousand clean files measure clean" "0" "$?"
rm -rf "${WORK}/many"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all real-arm-guard checks passed"
