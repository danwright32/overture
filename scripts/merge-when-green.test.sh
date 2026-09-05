#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/shell-assertions.sh"

# Coverage for merge-when-green.sh's classify_stop_reason (#625): whether a check-pr-ci.sh
# output means "stop polling, and why" or "keep polling". Real-shaped fixtures of
# check-pr-ci.sh's actual output strings, not the live gh API, since this is a pure decision
# over already-produced text.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./merge-when-green.sh
source "${SCRIPT_DIR}/merge-when-green.sh"
set +e

FAILURES=0

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

# A PR with a merge conflict: check-pr-ci.sh's check_mergeable exits before it ever finds any
# check runs, so this is the ONLY line of output, unlike the other cases below.
CONFLICT_OUTPUT="PR #625 on danwright32/overture, commit abc1234

Unmergeable: PR #625 has a merge conflict against its base branch. GitHub never runs CI checks on a PR it can't merge, so waiting here would just time out. Resolve the conflict, then rerun."
assert_equals "a merge conflict is classified as conflict" "conflict" "$(classify_stop_reason "${CONFLICT_OUTPUT}")"

FAILED_OUTPUT="PR #1 on danwright32/overture, commit abc1234

typecheck-and-test: Failed

Not every check has actually passed yet. Do not merge on the strength of pending or no failure yet alone."
assert_equals "a genuine check failure is classified as failed" "failed" "$(classify_stop_reason "${FAILED_OUTPUT}")"

PENDING_OUTPUT="PR #1 on danwright32/overture, commit abc1234

typecheck-and-test: Pending

Not every check has actually passed yet. Do not merge on the strength of pending or no failure yet alone."
assert_equals "still-pending checks are classified as keep-polling (empty)" "" "$(classify_stop_reason "${PENDING_OUTPUT}")"

echo
# --- base branch health (#1006 fallout) -------------------------------------------------
#
# check_pr_ci asks "did THIS branch pass". Nothing asked "is main green BEFORE I land on it",
# and on 2026-07-16 PR #1004 was merged onto a main that had been red for 29 minutes. Its own
# branch genuinely passed, so every existing gate reported truthfully and the merge still made a
# bad situation ambiguous: once a second change lands on a red main, nobody can tell which one
# broke it.
#
# A red base BLOCKS, but must be overridable, or the fix that makes main green could never be
# merged: the gate would deadlock exactly when it matters most.
#
# An UNKNOWN base does NOT block. It is not evidence of breakage, and GitHub's Actions API
# returned 503 for the whole of this session's investigation. A gate that stops all work during
# someone else's outage is a worse failure than the one it prevents. It warns instead, and the
# PR's own checks remain the real gate.

assert_equals "a green base is fine, no stop reason" \
  "" "$(base_branch_stop_reason "success")"

assert_equals "a red base blocks the merge" \
  "base-red" "$(base_branch_stop_reason "failure")"

# A cancelled or timed-out base is not a pass. It has NOT been seen to be green, which is the
# whole point: this repo's rule is that absence of failure is not a pass.
assert_equals "a cancelled base blocks the merge" \
  "base-red" "$(base_branch_stop_reason "cancelled")"
assert_equals "a timed-out base blocks the merge" \
  "base-red" "$(base_branch_stop_reason "timed_out")"

# The override exists so the FIX for a red main can land. Explicit, never a default.
assert_equals "an explicit override lets a merge land on a red base" \
  "" "$(base_branch_stop_reason "failure" "allow-red-base")"

# An API outage, an empty run list, or a base whose run is still going: unknown, not red.
assert_equals "an unknown base warns rather than blocks" \
  "base-unknown" "$(base_branch_stop_reason "")"
assert_equals "a base still running is unknown, not red" \
  "base-unknown" "$(base_branch_stop_reason "in_progress")"

# --- the WIRE from main() into the base-branch gate --------------------------------------
#
# The decision above is pure and tested. Whether main() actually CONSULTS it before merging is a
# SEPARATE claim, and by this repo's own history the more important one: #887's guard sat green
# across 1,829 tests with its wire cut, and #986's persistence test only earned trust once it was
# seen to fail with the assignment removed. So this drives the real main(), with gh and
# check-pr-ci.sh stubbed, and asserts on the thing that actually matters: did a merge happen.
#
# Cut the `case "$(base_branch_stop_reason ...)"` block out of main() and
# "a red base is not merged onto" flips to "merged". That is the mutation this exists to catch.

# Runs the REAL main() with a passing check-pr-ci.sh and a stubbed gh, and reports whether
# `gh pr merge` was reached. Subshell, because main() exits.
run_main_with_stubs() {
  local base_conclusion="$1" override="${2:-}"
  local tmp
  tmp="$(fixture_scratch_dir)"

  # A check-pr-ci.sh that reports a genuine pass, so the ONLY thing that can stop the merge is
  # the base-branch gate under test.
  cat > "${tmp}/check-pr-ci.sh" <<'STUB'
#!/usr/bin/env bash
echo "PR #1 on danwright32/overture, commit abc1234"
echo "typecheck-and-test: Passed"
exit 0
STUB
  chmod +x "${tmp}/check-pr-ci.sh"

  (
    SCRIPT_DIR="${tmp}"
    gh_as_danwright32() {
      case "$*" in
        # The completeness enumeration the merge now refuses to skip. Matched BEFORE the general
        # "pr view" arm, which answers everything with "main" and would otherwise be read as a
        # body that answers nothing, refusing every merge these fixtures exist to assert.
        *"--json body"*) echo "Writers: none. Readers: none. Siblings: swept. Guards seen to fail: yes. Premise re-checked: held." ;;
        *"pr view"*)   echo "main" ;;
        *"run list"*)  echo "${base_conclusion}" ;;
        *"pr merge"*)  touch "${tmp}/MERGED" ;;
      esac
    }
    main 1 900 ${override} >/dev/null 2>&1
  )

  if [[ -f "${tmp}/MERGED" ]]; then echo "merged"; else echo "not-merged"; fi
  rm -rf "${tmp}"
}

# THE case. The PR itself passed; the base is red; nothing may be merged.
assert_equals "a red base is not merged onto, even when the PR itself passed" \
  "not-merged" "$(run_main_with_stubs "failure")"

# The gate must not block a healthy merge, or it would be discovered by everything breaking.
assert_equals "a green base is merged onto" \
  "merged" "$(run_main_with_stubs "success")"

# The override has to actually reach the merge, or the fix for a red main could never land.
assert_equals "an override lets the fix for a red main land" \
  "merged" "$(run_main_with_stubs "failure" "allow-red-base")"

# An API outage must not stop work: the PR's own checks are still the real gate.
assert_equals "an unknown base still merges, on the PR's own checks" \
  "merged" "$(run_main_with_stubs "")"

echo
# --- pbxproj freshness gate (#1368, Decision 2) -----------------------------------------
#
# merge-when-green trusts remote CI, but since #1347 remote CI no longer runs the Swift/pbxproj side at
# all, so a STALE committed project.pbxproj could ride in here unseen. Decision 2: verify freshness, but
# only when the branch actually touches the Mac app (a branch that changed nothing under mac/ cannot have
# changed the generated project). paths_touch_mac_project is that pure decision over the branch's file list.

assert_equals "a new Mac source file needs the freshness check" \
  "yes" "$(paths_touch_mac_project "mac/Overture/UI/NewView.swift")"
assert_equals "a project.yml change needs the freshness check" \
  "yes" "$(paths_touch_mac_project "mac/project.yml")"
# A mixed diff: any single mac/ app path is enough.
assert_equals "a mixed diff touching the Mac app needs the check" \
  "yes" "$(paths_touch_mac_project "docs/contracts.md
mac/OvertureTests/FooTests.swift")"
# Nothing under mac/: cannot have changed the generated project.
assert_equals "a TypeScript-only diff needs no check" \
  "" "$(paths_touch_mac_project "src/lib/importHistory.ts
docs/contracts.md")"
assert_equals "a repo-scripts-only diff needs no check" \
  "" "$(paths_touch_mac_project "scripts/check-pbxproj-fresh.sh")"
# mac/scripts and mac/build never feed xcodegen's project generation, so they don't trigger it.
assert_equals "a mac/scripts-only diff needs no check" \
  "" "$(paths_touch_mac_project "mac/scripts/run-tests-locked.sh")"
assert_equals "a mac/build-only diff needs no check" \
  "" "$(paths_touch_mac_project "mac/build/Build/Products/Release/Overture.app/x")"

echo
# --- the WIRE from main() into the pbxproj gate ------------------------------------------
#
# The decision above is pure. Whether main() actually BLOCKS a stale-pbxproj Mac-touching branch is the
# separate, load-bearing claim (the #887 lesson: a guard with its wire cut sat green for 1,829 tests).
# Drive the real main() with a Mac-touching file list and a stubbed freshness verdict, asserting on the
# only thing that matters: did a merge happen. Cut the `exit 1` and "stale is NOT merged" flips to merged.
run_main_with_pbxproj() {
  local fresh_result="$1"   # "fresh" or "stale"
  local tmp
  tmp="$(fixture_scratch_dir)"
  cat > "${tmp}/check-pr-ci.sh" <<'STUB'
#!/usr/bin/env bash
echo "PR #1 on danwright32/overture, commit abc1234"
echo "typecheck-and-test: Passed"
exit 0
STUB
  chmod +x "${tmp}/check-pr-ci.sh"
  (
    SCRIPT_DIR="${tmp}"
    gh_as_danwright32() {
      case "$*" in
        # The completeness enumeration the merge now refuses to skip. Matched BEFORE the general
        # "pr view" arm, which answers everything with "main" and would otherwise be read as a
        # body that answers nothing, refusing every merge these fixtures exist to assert.
        *"--json body"*) echo "Writers: none. Readers: none. Siblings: swept. Guards seen to fail: yes. Premise re-checked: held." ;;
        *"--json files"*) echo "mac/Overture/UI/NewView.swift" ;;
        *"pr view"*)      echo "main" ;;
        *"run list"*)     echo "success" ;;
        *"pr merge"*)     touch "${tmp}/MERGED" ;;
      esac
    }
    # Stub the real fetch+worktree+xcodegen helper: the wire under test is whether main() heeds its verdict.
    verify_branch_pbxproj_fresh() { [[ "${fresh_result}" == "fresh" ]]; }
    main 1 900 >/dev/null 2>&1
  )
  if [[ -f "${tmp}/MERGED" ]]; then echo "merged"; else echo "not-merged"; fi
  rm -rf "${tmp}"
}

assert_equals "a Mac-touching branch with a fresh pbxproj merges" \
  "merged" "$(run_main_with_pbxproj "fresh")"
assert_equals "a Mac-touching branch with a STALE pbxproj is not merged" \
  "not-merged" "$(run_main_with_pbxproj "stale")"

# #2199: a red that no runner ever picked up stops the poll IMMEDIATELY and as its own reason. Checked
# before the coarser failure rule, since the never-started line is a red too and would be swallowed by
# it, which is the whole way the two got confused for thirty minutes on 2026-08-06.
NEVER_STARTED_OUTPUT="typecheck-and-test: Never started: no runner was ever assigned, so nothing ran. This is GitHub, not your code."
assert_equals "a check no runner picked up stops as its own reason" \
  "never-started" "$(classify_stop_reason "${NEVER_STARTED_OUTPUT}")"

# The other direction, so this cannot become an excuse for a genuine red.
assert_equals "a real failing test is still classified as failed" \
  "failed" "$(classify_stop_reason "typecheck-and-test: Failed")"

# --- the completeness enumeration: this merge path refuses a thin PR body too ---
# Every stub above answers with a COMPLETE body, so the guard would be entirely untested here and
# deleting it from this script would leave all of them green. The two merge paths have to be covered
# alike, or the uncovered one becomes the way round the check (L30).
#
# The subshell reports by EXIT STATUS, not by touching FAILURES. A subshell gets its own copy of the
# variable, so incrementing it in there prints FAIL while the summary counts zero and the script
# exits 0: a test that says it failed and reports success. Found by breaking the guard and watching
# exactly that happen.
completeness_refusal_check() (
  tmp="$(fixture_scratch_dir)"
  trap 'rm -rf "${tmp}"' EXIT
  SCRIPT_DIR="${tmp}"
  gh_as_danwright32() {
    case "$*" in
      *"--json body"*) echo "Fixes the thing. Tests pass." ;;
      *"pr view"*)     echo "main" ;;
      *"run list"*)    echo "success" ;;
      *"pr merge"*)    touch "${tmp}/MERGED" ;;
    esac
  }
  # A 2 second ceiling, not 900: with the guard gone this does not refuse, it falls through to the CI
  # polling loop, and an unbounded wait turns a failing test into a hung one that reports nothing.
  out="$( ( main 1 2 ) 2>&1 )"
  [[ "${out}" == *"REFUSING to merge"* ]] || exit 1
  [[ -e "${tmp}/MERGED" ]] && exit 2
  exit 0
)

completeness_refusal_check
case $? in
  0) echo "ok - merge-when-green refuses a PR body that skips the enumeration"
     echo "ok - a refused PR is not merged" ;;
  1) echo "FAIL - merge-when-green did not refuse a PR body that skips the enumeration"
     FAILURES=$((FAILURES + 1)) ;;
  2) echo "FAIL - a refused PR was merged anyway"
     FAILURES=$((FAILURES + 1)) ;;
esac

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All merge-when-green.sh classification fixtures passed."
  exit 0
else
  echo "${FAILURES} merge-when-green.sh classification fixture(s) failed."
  exit 1
fi
