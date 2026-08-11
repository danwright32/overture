#!/usr/bin/env bash
set -uo pipefail

# Coverage for verify-and-merge-branch.sh's verify_and_merge orchestration (#525): merge ONLY
# when the branch's own local suite comes back clean, and always clean up the throwaway worktree
# on both the happy and failure paths. Stubs every side-effecting step (resolve_pr, setup_worktree,
# run_full_suite, cleanup_worktree, merge_pr) so this never touches real git, gh, or xcodebuild.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./verify-and-merge-branch.sh
source "${SCRIPT_DIR}/verify-and-merge-branch.sh"
set +e

FAILURES=0

# The completeness enumeration AGENTS.md demands and the merge now refuses to skip. Stubbed here for
# every existing case, so those cases keep testing what they were written to test (the merge decision)
# rather than becoming tests of the new guard.
COMPLETE_PR_BODY='Writers: none new. Readers: none new. Siblings: swept. Guards seen to fail: yes.'

# A missing helper is not a failing test, it is a line that does nothing while the summary reports
# every fixture passing. Three assertions were written against this name before it existed and did
# exactly that, so it is defined here rather than left to whoever next needs it.
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected to contain: ${needle}"
    echo "  in: ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_equals() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

reset_stubs() {
  MERGE_CALLED=""
  MERGE_BRANCH=""
  CLEANUP_CALLED=""
  SETUP_CALLED=""
  COMBINE_CALLED=""
  SUITE_RAN=""
  LOCAL_BRANCH_DELETED=""
}

# --- happy path: a clean suite merges the resolved PR and cleans up the worktree ---
reset_stubs
resolve_pr() { PR_NUMBER="42"; PR_BRANCH="feature-x"; PR_MERGEABLE="MERGEABLE"; PR_BODY="${COMPLETE_PR_BODY}"; }
setup_worktree() { SETUP_CALLED="$1"; WORKTREE_DIR="/fake/worktree"; }
combine_with_main() { COMBINE_CALLED="$1"; return 0; }
run_full_suite() { SUITE_RAN="yes"; return 0; }
cleanup_worktree() { CLEANUP_CALLED="$1"; }
merge_pr() { MERGE_CALLED="$1"; }

verify_and_merge "42" >/dev/null 2>&1
assert_equals "a clean suite merges the right PR" "42" "${MERGE_CALLED}"
assert_equals "the worktree is cleaned up after a clean run" "/fake/worktree" "${CLEANUP_CALLED}"
# #2353: what gets verified must be what will EXIST after merging, not what the branch was cut
# from. Two changes that are each green can merge into a broken main (L85), so current main is
# combined into the throwaway worktree before the suite is allowed to judge it.
assert_equals "current main is combined into the worktree before the suite runs" \
  "/fake/worktree" "${COMBINE_CALLED}"

# --- failure path: a failing suite never merges, but still cleans up the worktree ---
reset_stubs
resolve_pr() { PR_NUMBER="43"; PR_BRANCH="feature-y"; PR_MERGEABLE="MERGEABLE"; PR_BODY="${COMPLETE_PR_BODY}"; }
setup_worktree() { SETUP_CALLED="$1"; WORKTREE_DIR="/fake/worktree-2"; }
combine_with_main() { COMBINE_CALLED="$1"; return 0; }
run_full_suite() { SUITE_RAN="yes"; return 1; }
cleanup_worktree() { CLEANUP_CALLED="$1"; }
merge_pr() { MERGE_CALLED="called-with-$1"; }

verify_and_merge "43" >/dev/null 2>&1
assert_equals "a failing suite never merges" "" "${MERGE_CALLED}"
assert_equals "the worktree is still cleaned up after a failing run" "/fake/worktree-2" "${CLEANUP_CALLED}"

# --- #2353: a branch that cannot be combined with current main is never verified or merged ---
# The suite must not run at all in this case. A suite run over a half-merged or conflicted tree
# would be judging a state that will never exist, and it could just as easily come back GREEN,
# which is the reading that would send a broken combination to main.
reset_stubs
resolve_pr() { PR_NUMBER="47"; PR_BRANCH="feature-conflicted"; PR_MERGEABLE="MERGEABLE"; PR_BODY="${COMPLETE_PR_BODY}"; }
setup_worktree() { SETUP_CALLED="$1"; WORKTREE_DIR="/fake/worktree-5"; }
combine_with_main() { COMBINE_CALLED="$1"; return 1; }
run_full_suite() { SUITE_RAN="yes"; return 0; }
cleanup_worktree() { CLEANUP_CALLED="$1"; }
merge_pr() { MERGE_CALLED="$1"; }

verify_and_merge "47" >/dev/null 2>&1
combine_exit=$?
assert_equals "a branch that will not combine with main is never merged" "" "${MERGE_CALLED}"
assert_equals "a branch that will not combine with main is never judged by the suite" "" "${SUITE_RAN}"
assert_equals "the worktree is cleaned up after a failed combine" "/fake/worktree-5" "${CLEANUP_CALLED}"
assert_equals "a failed combine reports failure to the caller" "1" "${combine_exit}"

# --- a merge-conflicted PR is never verified (no worktree) or merged ---
reset_stubs
resolve_pr() { PR_NUMBER="44"; PR_BRANCH="feature-z"; PR_MERGEABLE="CONFLICTING"; PR_BODY="${COMPLETE_PR_BODY}"; }
setup_worktree() { SETUP_CALLED="$1"; WORKTREE_DIR="/fake/worktree-3"; }
run_full_suite() { return 0; }
cleanup_worktree() { CLEANUP_CALLED="$1"; }
merge_pr() { MERGE_CALLED="$1"; }

verify_and_merge "44" >/dev/null 2>&1
assert_equals "a merge conflict never sets up a worktree" "" "${SETUP_CALLED}"
assert_equals "a merge conflict never merges" "" "${MERGE_CALLED}"

# --- an unresolvable identifier bails before touching anything else ---
reset_stubs
resolve_pr() { PR_NUMBER=""; PR_BRANCH=""; PR_MERGEABLE=""; PR_BODY="${COMPLETE_PR_BODY}"; }
setup_worktree() { SETUP_CALLED="$1"; }
merge_pr() { MERGE_CALLED="$1"; }

verify_and_merge "does-not-exist" >/dev/null 2>&1
assert_equals "an unresolvable PR never sets up a worktree" "" "${SETUP_CALLED}"
assert_equals "an unresolvable PR never merges" "" "${MERGE_CALLED}"

# --- #2234: the merge tidies up the local branch it just landed ---
# Built is not wired (L3). checkout-tidy.sh's own fixture proves the DECISION is right; these prove
# this script actually asks it, and asks it about the branch that was merged rather than some other
# one. Both halves stubbed, so nothing here runs gh or deletes a real ref.
reset_stubs
# merge_pr is the REAL one for these two cases, because it is the function under test, and the
# blocks above left a stub of it in scope. Re-sourcing restores every real definition, so the
# stubs below have to come after it.
# shellcheck source=./verify-and-merge-branch.sh
source "${SCRIPT_DIR}/verify-and-merge-branch.sh"
# The script under test opens with `set -euo pipefail`, so re-sourcing it turns `errexit` back on
# and the next failing command would end this run silently, part way through, with no summary. That
# reads as an ordinary pass to anything checking the exit code of the last thing printed.
set +e
resolve_pr() { PR_NUMBER="45"; PR_BRANCH="feature-tidy"; PR_MERGEABLE="MERGEABLE"; PR_BODY="${COMPLETE_PR_BODY}"; }
setup_worktree() { SETUP_CALLED="$1"; WORKTREE_DIR="/fake/worktree-4"; }
combine_with_main() { COMBINE_CALLED="$1"; return 0; }
run_full_suite() { return 0; }
cleanup_worktree() { CLEANUP_CALLED="$1"; }
gh_as_danwright32() { :; }
delete_merged_local_branch() { LOCAL_BRANCH_DELETED="$1"; }
# merge_pr's two trailing side-effect scripts are neutralised by pointing REPO_ROOT at an empty
# directory, so they are simply absent; both are already `|| true` in the source, so their absence
# changes nothing else.
REPO_ROOT="$(mktemp -d)"

verify_and_merge "45" >/dev/null 2>&1
assert_equals "the merged branch's local ref is handed to the cleanup" "feature-tidy" "${LOCAL_BRANCH_DELETED}"

# The failing path must not tidy anything: there was no merge, so the branch is still live work.
reset_stubs
resolve_pr() { PR_NUMBER="46"; PR_BRANCH="feature-unmerged"; PR_MERGEABLE="MERGEABLE"; PR_BODY="${COMPLETE_PR_BODY}"; }
run_full_suite() { return 1; }
delete_merged_local_branch() { LOCAL_BRANCH_DELETED="$1"; }

verify_and_merge "46" >/dev/null 2>&1
assert_equals "a failed suite never deletes the local branch" "" "${LOCAL_BRANCH_DELETED}"

# --- the completeness enumeration: an incomplete body stops the merge before anything expensive ---
# Every case above now stubs a COMPLETE body, which would leave the new guard entirely untested: they
# would all pass with it deleted. This is the case that fails when it is not there.
#
# Run in a subshell, because refusing EXITS. That is deliberate (a warning in a merge script's output
# is read by nobody at the moment it matters), and it is also why an unstubbed PR_BODY killed this
# whole file silently while it was being written: `set -u` plus an exit is a traceless death.
reset_stubs
resolve_pr() { PR_NUMBER="48"; PR_BRANCH="feature-thin-body"; PR_MERGEABLE="MERGEABLE"; PR_BODY="Fixes the thing. Tests pass."; }
setup_worktree() { SETUP_CALLED="$1"; WORKTREE_DIR="/fake/worktree-6"; }
combine_with_main() { COMBINE_CALLED="$1"; return 0; }
run_full_suite() { SUITE_RAN="yes"; return 0; }
cleanup_worktree() { CLEANUP_CALLED="$1"; }
merge_pr() { MERGE_CALLED="$1"; }

REFUSAL="$( ( verify_and_merge "48" ) 2>&1 )"
REFUSAL_STATUS=$?

assert_contains "an incomplete PR body is refused" "${REFUSAL}" "REFUSING to merge PR #48"
assert_contains "the refusal names an item that was not answered" "${REFUSAL}" "siblings"
assert_contains "the refusal says passing it is not evidence of completeness" "${REFUSAL}" "not evidence"
assert_equals "the refusal is not a warning" "1" "${REFUSAL_STATUS}"

# The whole point of refusing EARLY: none of the expensive or destructive work may have happened, so
# the fix costs seconds and no re-run of anything.
assert_equals "a refused PR never sets up a worktree" "" "${SETUP_CALLED}"
assert_equals "a refused PR never runs the suite" "" "${SUITE_RAN}"
assert_equals "a refused PR never merges" "" "${MERGE_CALLED}"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All verify-and-merge-branch.sh fixtures passed."
  exit 0
else
  echo "${FAILURES} verify-and-merge-branch.sh fixture(s) failed."
  exit 1
fi
