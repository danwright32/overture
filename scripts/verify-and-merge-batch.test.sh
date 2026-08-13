#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501).
# shellcheck source=../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"

# Coverage for verify-and-merge-batch.sh's verify_and_merge_batch orchestration (#2602): several PRs
# verified together in ONE suite run, merged only if that combined run is clean, and refused up front
# (before anything expensive) when any one of them cannot be part of a batch.
#
# Every side-effecting step is stubbed, so nothing here touches real git, gh or xcodebuild. The two
# properties that make this script worth having are asserted directly: the suite runs exactly ONCE for
# the whole batch, and a red run says the failure belongs to the COMBINATION and names every branch in
# it, since a combined run cannot attribute a failure to one branch.
#
# The real combine (a git merge into a real worktree) is driven against throwaway repos at the end,
# because a conflict has to be a real conflict for the refusal to mean anything.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./verify-and-merge-batch.sh
source "${SCRIPT_DIR}/verify-and-merge-batch.sh"
# The sourced scripts' own `set -euo pipefail` is now active. Turn errexit off so one failing assertion
# does not end this run part way through with no summary, which reads as an ordinary pass to anything
# checking only the exit code.
set +e

FAILURES=0

BATCH_OUT_FILE=""

# Runs verify_and_merge_batch in THIS shell, capturing its output in BATCH_OUTPUT and its status in
# BATCH_STATUS. Not `$(...)`: command substitution runs a subshell, so every variable a stub records
# (MERGED, RELEASE_CALLED, SUITE_RUNS) would be thrown away with it, and the assertions that read them
# afterwards would compare two empty strings and pass. Three cases here did exactly that while this
# file was being written.
run_batch() {
  BATCH_OUT_FILE="${BATCH_OUT_FILE:-$(mktemp "${TMPDIR:-/tmp}/batch-out.XXXXXX")}"
  BATCH_STATUS=0
  verify_and_merge_batch "$@" >"${BATCH_OUT_FILE}" 2>&1 || BATCH_STATUS=$?
  BATCH_OUTPUT="$(cat "${BATCH_OUT_FILE}")"
}

# The completeness enumeration AGENTS.md demands, which the merge path refuses to skip. Stubbed for
# every case that is testing something else, so those cases keep testing the batch decision rather than
# becoming tests of that guard.
COMPLETE_PR_BODY='Writers: none new. Readers: none new. Siblings: swept. Guards seen to fail: yes.'

reset_stubs() {
  SUITE_RUNS=0
  SETUP_BRANCH=""
  COMBINED_BRANCHES=""
  MERGED=""
  RELEASE_CALLED=""
  MERGE_RESULTS=()
}

# resolve_pr keyed by identifier, so one stub serves a whole batch. The branch name is derived from the
# number, which is enough for every assertion below and keeps each case's setup to one line.
stub_resolve() {
  resolve_pr() {
    PR_NUMBER="$1"
    PR_BRANCH="branch-$1"
    PR_MERGEABLE="MERGEABLE"
    PR_BODY="${COMPLETE_PR_BODY}"
  }
}

# --- happy path: three PRs, ONE suite run, all three merged ---
reset_stubs
stub_resolve
setup_worktree() { SETUP_BRANCH="$1"; WORKTREE_DIR="/fake/worktree"; }
combine_branches() { shift; COMBINED_BRANCHES="$*"; return 0; }
run_full_suite() { SUITE_RUNS=$((SUITE_RUNS + 1)); return 0; }
release_verify_slot() { RELEASE_CALLED="yes"; }
merge_pr() { MERGED="${MERGED}${1} "; return 0; }

verify_and_merge_batch "11" "12" "13" >/dev/null 2>&1
BATCH_STATUS=$?
assert_eq "a clean combined run merges every PR in the batch" "11 12 13 " "${MERGED}"
# The whole point of the script: three PRs cost ONE suite run, not three.
assert_eq "the suite runs exactly once for the whole batch" "1" "${SUITE_RUNS}"
assert_eq "the verify worktree starts from current main, so the tree is what will exist after merging" \
  "main" "${SETUP_BRANCH}"
assert_eq "every branch is combined into it" "branch-11 branch-12 branch-13" "${COMBINED_BRANCHES}"
assert_eq "the verify slot is released" "yes" "${RELEASE_CALLED}"
assert_eq "a clean batch reports success" "0" "${BATCH_STATUS}"

# --- a red combined run merges NOTHING, and says the red belongs to the combination ---
reset_stubs
stub_resolve
setup_worktree() { SETUP_BRANCH="$1"; WORKTREE_DIR="/fake/worktree"; }
combine_branches() { return 0; }
run_full_suite() { SUITE_RUNS=$((SUITE_RUNS + 1)); return 1; }
release_verify_slot() { RELEASE_CALLED="yes"; }
merge_pr() { MERGED="${MERGED}${1} "; return 0; }

run_batch "21" "22"
RED_OUTPUT="${BATCH_OUTPUT}"
RED_STATUS="${BATCH_STATUS}"
assert_eq "a failing combined run merges nothing at all" "" "${MERGED}"
assert_eq "a failing combined run reports failure" "1" "${RED_STATUS}"
assert_eq "the verify slot is released after a red run too" "yes" "${RELEASE_CALLED}"
# L85 is the reason the combination exists, and it is also why the red cannot be pinned on one branch.
# Saying so is the difference between a next step and a wrong guess.
assert_contains "the red is attributed to the combination, not to a branch" \
  "${RED_OUTPUT}" "belongs to the COMBINATION"
assert_contains "every branch in the combination is named" "${RED_OUTPUT}" "branch-21"
assert_contains "including the last one, which is the one a reader would otherwise blame" \
  "${RED_OUTPUT}" "branch-22"
assert_contains "and it says what to do next" "${RED_OUTPUT}" "smaller set"

# --- a branch that will not combine: no suite run, no merge, and the branch is NAMED ---
reset_stubs
stub_resolve
setup_worktree() { SETUP_BRANCH="$1"; WORKTREE_DIR="/fake/worktree"; }
combine_branches() { echo "Cannot combine branch-32 with what is already in the verify worktree: the merge conflicts." >&2; return 1; }
run_full_suite() { SUITE_RUNS=$((SUITE_RUNS + 1)); return 0; }
release_verify_slot() { RELEASE_CALLED="yes"; }
merge_pr() { MERGED="${MERGED}${1} "; return 0; }

run_batch "31" "32"
CONFLICT_OUTPUT="${BATCH_OUTPUT}"
CONFLICT_STATUS="${BATCH_STATUS}"
assert_eq "a conflicting combination is never judged by the suite" "0" "${SUITE_RUNS}"
assert_eq "a conflicting combination merges nothing" "" "${MERGED}"
assert_eq "the slot is released after a failed combine" "yes" "${RELEASE_CALLED}"
assert_eq "a failed combine reports failure" "1" "${CONFLICT_STATUS}"
assert_contains "the refusal names the branch that would not go in" "${CONFLICT_OUTPUT}" "branch-32"

# --- one PR conflicting on GitHub refuses the WHOLE batch, before anything expensive ---
reset_stubs
resolve_pr() {
  PR_NUMBER="$1"
  PR_BRANCH="branch-$1"
  PR_BODY="${COMPLETE_PR_BODY}"
  if [[ "$1" == "42" ]]; then PR_MERGEABLE="CONFLICTING"; else PR_MERGEABLE="MERGEABLE"; fi
}
setup_worktree() { SETUP_BRANCH="$1"; WORKTREE_DIR="/fake/worktree"; }
combine_branches() { return 0; }
run_full_suite() { SUITE_RUNS=$((SUITE_RUNS + 1)); return 0; }
release_verify_slot() { RELEASE_CALLED="yes"; }
merge_pr() { MERGED="${MERGED}${1} "; return 0; }

verify_and_merge_batch "41" "42" "43" >/dev/null 2>&1
assert_eq "one unmergeable PR sets up no worktree" "" "${SETUP_BRANCH}"
assert_eq "one unmergeable PR costs no suite run" "0" "${SUITE_RUNS}"
assert_eq "one unmergeable PR merges nothing, including the mergeable ones beside it" "" "${MERGED}"

# --- an unresolvable identifier refuses the whole batch, before anything expensive ---
reset_stubs
resolve_pr() {
  PR_BRANCH=""
  PR_MERGEABLE="MERGEABLE"
  PR_BODY="${COMPLETE_PR_BODY}"
  if [[ "$1" == "nope" ]]; then PR_NUMBER=""; else PR_NUMBER="$1"; PR_BRANCH="branch-$1"; fi
}
setup_worktree() { SETUP_BRANCH="$1"; WORKTREE_DIR="/fake/worktree"; }
combine_branches() { return 0; }
run_full_suite() { SUITE_RUNS=$((SUITE_RUNS + 1)); return 0; }
merge_pr() { MERGED="${MERGED}${1} "; return 0; }

verify_and_merge_batch "51" "nope" >/dev/null 2>&1
assert_eq "an unresolvable identifier costs no suite run" "0" "${SUITE_RUNS}"
assert_eq "an unresolvable identifier merges nothing" "" "${MERGED}"

# --- the same PR named twice is refused rather than quietly deduplicated ---
reset_stubs
stub_resolve
setup_worktree() { SETUP_BRANCH="$1"; WORKTREE_DIR="/fake/worktree"; }
combine_branches() { return 0; }
run_full_suite() { SUITE_RUNS=$((SUITE_RUNS + 1)); return 0; }
merge_pr() { MERGED="${MERGED}${1} "; return 0; }

run_batch "61" "61"
DUPE_OUTPUT="${BATCH_OUTPUT}"
DUPE_STATUS="${BATCH_STATUS}"
assert_eq "a repeated PR is refused" "1" "${DUPE_STATUS}"
assert_contains "the refusal says which PR was named twice" "${DUPE_OUTPUT}" "#61 was named twice"
assert_eq "a repeated PR costs no suite run" "0" "${SUITE_RUNS}"
assert_eq "a repeated PR merges nothing" "" "${MERGED}"

# --- an incomplete PR body refuses the whole batch, before anything expensive ---
# Every case above stubs a COMPLETE body, so without this one they would all pass with the guard
# deleted. Run in a subshell, because refusing EXITS.
reset_stubs
resolve_pr() {
  PR_NUMBER="$1"
  PR_BRANCH="branch-$1"
  PR_MERGEABLE="MERGEABLE"
  if [[ "$1" == "72" ]]; then PR_BODY="Fixes the thing. Tests pass."; else PR_BODY="${COMPLETE_PR_BODY}"; fi
}
setup_worktree() { SETUP_BRANCH="$1"; WORKTREE_DIR="/fake/worktree"; }
combine_branches() { return 0; }
run_full_suite() { SUITE_RUNS=$((SUITE_RUNS + 1)); return 0; }
merge_pr() { MERGED="${MERGED}${1} "; return 0; }

THIN_OUTPUT="$( ( verify_and_merge_batch "71" "72" ) 2>&1 )"
THIN_STATUS=$?
assert_contains "an incomplete PR body in the batch is refused" "${THIN_OUTPUT}" "REFUSING to merge PR #72"
assert_eq "the refusal is not a warning" "1" "${THIN_STATUS}"
assert_eq "a refused batch costs no suite run" "0" "${SUITE_RUNS}"
assert_eq "a refused batch merges nothing" "" "${MERGED}"

# --- a verified PR that GitHub then refuses to merge is REPORTED, and the rest are still attempted ---
# GitHub squash-merges these one at a time, so the second can be refused for a reason the combined
# local run could not see. Stopping at the first failure would leave the rest unattempted and
# unreported, which is indistinguishable from never having been asked (L47).
reset_stubs
stub_resolve
setup_worktree() { SETUP_BRANCH="$1"; WORKTREE_DIR="/fake/worktree"; }
combine_branches() { return 0; }
run_full_suite() { return 0; }
release_verify_slot() { RELEASE_CALLED="yes"; }
merge_pr() {
  MERGED="${MERGED}${1} "
  [[ "$1" == "82" ]] && return 1
  return 0
}

run_batch "81" "82" "83"
PARTIAL_OUTPUT="${BATCH_OUTPUT}"
PARTIAL_STATUS="${BATCH_STATUS}"
assert_eq "a merge refused by GitHub does not stop the ones behind it" "81 82 83 " "${MERGED}"
assert_eq "a partly merged batch reports failure" "1" "${PARTIAL_STATUS}"
assert_contains "the summary says which PR was refused" "${PARTIAL_OUTPUT}" "REFUSED  PR #82"
assert_contains "and which ones landed" "${PARTIAL_OUTPUT}" "merged   PR #81"
assert_contains "including the one after the refusal" "${PARTIAL_OUTPUT}" "merged   PR #83"

echo
echo "--- the real combine, against throwaway git repos ---"

# The refusal above is only worth having if a real conflict really produces it, and if the tree is left
# clean rather than half-merged. Sourcing the script again first, because the cases above replaced
# combine_branches with stubs and these would otherwise test a stub (L1).
# shellcheck source=./verify-and-merge-batch.sh
source "${SCRIPT_DIR}/verify-and-merge-batch.sh"
set +e

FIX_ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/overture-batch-combine.XXXXXX")" && pwd -P)"
ORIGIN_BARE="${FIX_ROOT}/origin.git"
SEED="${FIX_ROOT}/seed"
git init -q --bare "${ORIGIN_BARE}"
git init -q -b main "${SEED}"
printf 'one\ntwo\nthree\n' > "${SEED}/shared.txt"
echo "base" > "${SEED}/untouched.txt"
git -C "${SEED}" add .
git -C "${SEED}" -c user.name=fixture -c user.email=fixture@localhost commit -qm main-one

# Two branches that touch DIFFERENT files, so they combine cleanly.
git -C "${SEED}" checkout -q -b tidy-a
echo "a" > "${SEED}/a.txt"
git -C "${SEED}" add a.txt
git -C "${SEED}" -c user.name=fixture -c user.email=fixture@localhost commit -qm a
git -C "${SEED}" checkout -q main
git -C "${SEED}" checkout -q -b tidy-b
echo "b" > "${SEED}/b.txt"
git -C "${SEED}" add b.txt
git -C "${SEED}" -c user.name=fixture -c user.email=fixture@localhost commit -qm b

# Two branches that rewrite the SAME line, which is the real conflict.
git -C "${SEED}" checkout -q main
git -C "${SEED}" checkout -q -b clash-a
printf 'one\nA\nthree\n' > "${SEED}/shared.txt"
git -C "${SEED}" -c user.name=fixture -c user.email=fixture@localhost commit -aqm clash-a
git -C "${SEED}" checkout -q main
git -C "${SEED}" checkout -q -b clash-b
printf 'one\nB\nthree\n' > "${SEED}/shared.txt"
git -C "${SEED}" -c user.name=fixture -c user.email=fixture@localhost commit -aqm clash-b
git -C "${SEED}" checkout -q main
git -C "${SEED}" push -q "${ORIGIN_BARE}" main tidy-a tidy-b clash-a clash-b
# `git init --bare` points HEAD at master, and nothing here ever creates one, so the clone below would
# warn about a nonexistent HEAD and land with no checkout at all.
git -C "${ORIGIN_BARE}" symbolic-ref HEAD refs/heads/main

CLONE="${FIX_ROOT}/clone"
git clone -q "${ORIGIN_BARE}" "${CLONE}"
REPO_ROOT="${CLONE}"
WORK="${FIX_ROOT}/work"
git -C "${CLONE}" worktree add -q --detach "${WORK}" origin/main

combine_branches "${WORK}" "tidy-a" "tidy-b" >/dev/null 2>&1
assert_eq "two branches touching different files combine cleanly" "0" "$?"
if [[ -f "${WORK}/a.txt" && -f "${WORK}/b.txt" ]]; then
  pass "the combined tree holds both branches' work"
else
  fail "the combined tree must hold both branches' work"
fi

git -C "${WORK}" checkout -q --force --detach origin/main
CLASH_OUTPUT="$(combine_branches "${WORK}" "clash-a" "clash-b" 2>&1)"
CLASH_STATUS=$?
assert_eq "two branches rewriting the same line are refused" "1" "${CLASH_STATUS}"
assert_contains "the refusal names the branch that would not go in" "${CLASH_OUTPUT}" "clash-b"
assert_contains "and says nothing was verified" "${CLASH_OUTPUT}" "Nothing was verified"
# A half-merged tree is the dangerous state: a suite run over it can come back green, and green is the
# reading that sends a broken combination to main.
if git -C "${WORK}" ls-files --unmerged | grep -q .; then
  fail "the conflicted merge must be aborted, leaving no half-merged tree behind"
else
  pass "the conflicted merge is aborted, so no suite can be run over a half-merged tree"
fi

git -C "${CLONE}" worktree remove --force "${WORK}" >/dev/null 2>&1
rm -rf "${FIX_ROOT}"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All verify-and-merge-batch.sh fixtures passed."
  exit 0
else
  echo "${FAILURES} verify-and-merge-batch.sh fixture(s) failed."
  exit 1
fi
