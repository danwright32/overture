#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/shell-assertions.sh"

# Coverage for verify-and-merge-branch.sh's verify_and_merge orchestration (#525): merge ONLY
# when the branch's own local suite comes back clean, and always release the verify slot on both
# the happy and failure paths. Stubs every side-effecting step (resolve_pr, setup_worktree,
# run_full_suite, release_verify_slot, merge_pr) so this never touches real git, gh, or xcodebuild.
# The PERSISTENT slot's own behaviour (#2601) is driven for real further down, against throwaway
# git repos.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./verify-and-merge-branch.sh
source "${SCRIPT_DIR}/verify-and-merge-branch.sh"
set +e

FAILURES=0

# Where the trial-merge stub records what it was asked, since the caller reads its output through a
# command substitution and a variable set inside that subshell never reaches an assertion.
TRIAL_MERGE_LOG="$(mktemp "${TMPDIR:-/tmp}/verify-merge-trial.XXXXXX")"
trap 'rm -f "${TRIAL_MERGE_LOG}"' EXIT

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
  RELEASE_CALLED=""
  SETUP_CALLED=""
  COMBINE_CALLED=""
  SUITE_RAN=""
  LOCAL_BRANCH_DELETED=""
  GATED_REFS=""
  GATE_RESULT=0
  COMMIT_REGEN_RESULT=0
  # #2812's two new steps, stubbed here rather than in every case: unstubbed, the gate would fetch from
  # the REAL origin and run xcodegen against a worktree path these cases invented.
  gate_branch_project_freshness() { shift; GATED_REFS="$*"; return "${GATE_RESULT}"; }
  commit_merge_regeneration() { return "${COMMIT_REGEN_RESULT}"; }
  # #3210's trial merge. Stubbed here rather than in every case, for reset_stubs' usual reason:
  # unstubbed it would fetch from the REAL origin and merge refs these cases invented. The default is
  # the outcome that keeps the pre-#3210 cases meaning what they were written to mean, a CONFLICTING
  # PR being refused.
  TRIAL_MERGE_RESULT="${TRIAL_MERGE_CONFLICTS}"
  TRIAL_MERGE_OUTPUT="docs/contracts.md"
  # Recorded through a FILE, not a variable. The caller reads this stub's conflicted-file list through
  # a command substitution, so the stub runs in a subshell and anything it assigns there dies with it:
  # an assertion on a plain variable would have read empty whatever the caller did, which is a fixture
  # that can only ever agree with itself.
  : > "${TRIAL_MERGE_LOG}"
  fetch_trial_merge_refs() { return 0; }
  trial_merge_conflicts() {
    printf '%s %s' "$1" "$2" > "${TRIAL_MERGE_LOG}"
    [[ -n "${TRIAL_MERGE_OUTPUT}" ]] && printf '%s\n' "${TRIAL_MERGE_OUTPUT}"
    return "${TRIAL_MERGE_RESULT}"
  }
}

# --- happy path: a clean suite merges the resolved PR and releases the verify slot ---
reset_stubs
resolve_pr() { PR_NUMBER="42"; PR_BRANCH="feature-x"; PR_MERGEABLE="MERGEABLE"; PR_BODY="${COMPLETE_PR_BODY}"; }
setup_worktree() { SETUP_CALLED="$1"; WORKTREE_DIR="/fake/worktree"; }
combine_with_main() { COMBINE_CALLED="$1"; return 0; }
run_full_suite() { SUITE_RAN="yes"; return 0; }
release_verify_slot() { RELEASE_CALLED="yes"; }
merge_pr() { MERGE_CALLED="$1"; }

verify_and_merge "42" >/dev/null 2>&1
assert_equals "a clean suite merges the right PR" "42" "${MERGE_CALLED}"
assert_equals "the verify slot is released after a clean run" "yes" "${RELEASE_CALLED}"
# #2353: what gets verified must be what will EXIST after merging, not what the branch was cut
# from. Two changes that are each green can merge into a broken main (L85), so current main is
# combined into the throwaway worktree before the suite is allowed to judge it.
assert_equals "current main is combined into the worktree before the suite runs" \
  "/fake/worktree" "${COMBINE_CALLED}"

# --- failure path: a failing suite never merges, but still releases the verify slot ---
reset_stubs
resolve_pr() { PR_NUMBER="43"; PR_BRANCH="feature-y"; PR_MERGEABLE="MERGEABLE"; PR_BODY="${COMPLETE_PR_BODY}"; }
setup_worktree() { SETUP_CALLED="$1"; WORKTREE_DIR="/fake/worktree-2"; }
combine_with_main() { COMBINE_CALLED="$1"; return 0; }
run_full_suite() { SUITE_RAN="yes"; return 1; }
release_verify_slot() { RELEASE_CALLED="yes"; }
merge_pr() { MERGE_CALLED="called-with-$1"; }

verify_and_merge "43" >/dev/null 2>&1
assert_equals "a failing suite never merges" "" "${MERGE_CALLED}"
assert_equals "the verify slot is still released after a failing run" "yes" "${RELEASE_CALLED}"

# --- #2353: a branch that cannot be combined with current main is never verified or merged ---
# The suite must not run at all in this case. A suite run over a half-merged or conflicted tree
# would be judging a state that will never exist, and it could just as easily come back GREEN,
# which is the reading that would send a broken combination to main.
reset_stubs
resolve_pr() { PR_NUMBER="47"; PR_BRANCH="feature-conflicted"; PR_MERGEABLE="MERGEABLE"; PR_BODY="${COMPLETE_PR_BODY}"; }
setup_worktree() { SETUP_CALLED="$1"; WORKTREE_DIR="/fake/worktree-5"; }
combine_with_main() { COMBINE_CALLED="$1"; return 1; }
run_full_suite() { SUITE_RAN="yes"; return 0; }
release_verify_slot() { RELEASE_CALLED="yes"; }
merge_pr() { MERGE_CALLED="$1"; }

verify_and_merge "47" >/dev/null 2>&1
combine_exit=$?
assert_equals "a branch that will not combine with main is never merged" "" "${MERGE_CALLED}"
assert_equals "a branch that will not combine with main is never judged by the suite" "" "${SUITE_RAN}"
assert_equals "the verify slot is released after a failed combine" "yes" "${RELEASE_CALLED}"
assert_equals "a failed combine reports failure to the caller" "1" "${combine_exit}"

# --- #2812: the branch's own project file is judged BEFORE anything is merged or regenerated ---
# These cases assert the DECISION on this path. gate_branch_project_freshness and
# commit_merge_regeneration are defined in verify-and-merge-branch.sh but driven for REAL, against
# throwaway repos carrying the merge driver and a miniature post-merge hook, in
# scripts/verify-and-merge-batch.test.sh, because the state they exist for takes two merges to reach.
#
# The single-branch path merges too, so the post-merge hook fires here as well and the combined tree's
# regeneration would otherwise be the only thing the freshness check ever saw. A stale branch must be
# refused before that, or committing the regeneration is a free pass on exactly what #1368 exists to
# catch: the stale file is what lands on main, whatever this worktree ends up holding.
reset_stubs
resolve_pr() { PR_NUMBER="49"; PR_BRANCH="feature-stale-project"; PR_MERGEABLE="MERGEABLE"; PR_BODY="${COMPLETE_PR_BODY}"; }
setup_worktree() { SETUP_CALLED="$1"; WORKTREE_DIR="/fake/worktree-7"; }
combine_with_main() { COMBINE_CALLED="$1"; return 0; }
run_full_suite() { SUITE_RAN="yes"; return 0; }
release_verify_slot() { RELEASE_CALLED="yes"; }
merge_pr() { MERGE_CALLED="$1"; }

verify_and_merge "49" >/dev/null 2>&1
assert_equals "both sides going into the tree are judged, not just the branch" \
  "feature-stale-project main" "${GATED_REFS}"

# The same case again with the gate refusing. Everything the first run recorded is cleared first, so
# what is asserted below is this run's doing rather than the previous one's leftovers.
MERGE_CALLED=""
COMBINE_CALLED=""
SUITE_RAN=""
RELEASE_CALLED=""
GATE_RESULT=1
verify_and_merge "49" >/dev/null 2>&1
assert_equals "a branch with a stale project file is never combined with main" "" "${COMBINE_CALLED}"
assert_equals "a branch with a stale project file is never judged by the suite" "" "${SUITE_RAN}"
assert_equals "a branch with a stale project file is never merged" "" "${MERGE_CALLED}"
assert_equals "the verify slot is released when the freshness gate refuses" "yes" "${RELEASE_CALLED}"

# --- #2812: a verify worktree left in a state this script will not commit is never merged ---
reset_stubs
COMMIT_REGEN_RESULT=1
resolve_pr() { PR_NUMBER="50"; PR_BRANCH="feature-odd-index"; PR_MERGEABLE="MERGEABLE"; PR_BODY="${COMPLETE_PR_BODY}"; }
setup_worktree() { SETUP_CALLED="$1"; WORKTREE_DIR="/fake/worktree-8"; }
combine_with_main() { COMBINE_CALLED="$1"; return 0; }
run_full_suite() { SUITE_RAN="yes"; return 0; }
release_verify_slot() { RELEASE_CALLED="yes"; }
merge_pr() { MERGE_CALLED="$1"; }

verify_and_merge "50" >/dev/null 2>&1
assert_equals "an index this script will not commit is never judged by the suite" "" "${SUITE_RAN}"
assert_equals "an index this script will not commit is never merged" "" "${MERGE_CALLED}"
assert_equals "the verify slot is released then too" "yes" "${RELEASE_CALLED}"

# --- a merge-conflicted PR is never verified (no worktree) or merged ---
reset_stubs
resolve_pr() { PR_NUMBER="44"; PR_BRANCH="feature-z"; PR_MERGEABLE="CONFLICTING"; PR_BODY="${COMPLETE_PR_BODY}"; }
setup_worktree() { SETUP_CALLED="$1"; WORKTREE_DIR="/fake/worktree-3"; }
run_full_suite() { return 0; }
release_verify_slot() { RELEASE_CALLED="yes"; }
merge_pr() { MERGE_CALLED="$1"; }

OUTPUT="$(verify_and_merge "44" 2>&1)"
assert_equals "a merge conflict never sets up a worktree" "" "${SETUP_CALLED}"
assert_equals "a merge conflict never merges" "" "${MERGE_CALLED}"
# #3210: the refusal says WHICH files collided. Without that, a real conflict and a collision this
# repo resolves by itself read exactly alike, and the only way to tell them apart was to update the
# branch by hand and pay for another full suite cycle.
assert_contains "the refusal names the file that really collided" "${OUTPUT}" "docs/contracts.md"
assert_contains "and says it is the kind somebody has to resolve" "${OUTPUT}" "This is the real kind"

# --- #3210: a collision this repo's own merge resolves is refused with a DIFFERENT reason ---
# GitHub computes `mergeable` with a plain text merge and cannot see this repo's .gitattributes merge
# driver, so any two branches touching the app's wording or its file list report as CONFLICTING. It
# still refuses, because GitHub will not merge a PR it reports that way whatever this Mac can resolve
# (PR #3196's own commits are the evidence: a pushed merge of main AND a pushed regeneration before it
# would go in). What changes is that the reader is told which kind of collision it is, in seconds, and
# handed the mechanical remedy, instead of paying a full extra suite cycle to find out.
reset_stubs
TRIAL_MERGE_RESULT="${TRIAL_MERGE_RESOLVED}"
TRIAL_MERGE_OUTPUT=""
resolve_pr() { PR_NUMBER="46"; PR_BRANCH="feature-generated"; PR_MERGEABLE="CONFLICTING"; PR_BODY="${COMPLETE_PR_BODY}"; }
setup_worktree() { SETUP_CALLED="$1"; WORKTREE_DIR="/fake/worktree-generated"; }
combine_with_main() { COMBINE_CALLED="$1"; return 0; }
run_full_suite() { SUITE_RAN="yes"; return 0; }
release_verify_slot() { RELEASE_CALLED="yes"; }
merge_pr() { MERGE_CALLED="$1"; }

OUTPUT="$(verify_and_merge "46" 2>&1)"
assert_equals "a collision this repo resolves still costs no suite run" "" "${SUITE_RAN}"
assert_equals "and is still never merged, because GitHub will not take it either" "" "${MERGE_CALLED}"
assert_contains "the reader is told it is the cheap kind" "${OUTPUT}" "This is the cheap kind"
assert_contains "and handed the command that changes GitHub's mind" "${OUTPUT}" "git merge origin/main"
# The remedy has to be one somebody can FOLLOW to the end. Two things about this repo make the obvious
# three steps wrong, and both were checked against the code rather than assumed: bringing main in fires
# scripts/hooks/post-merge, which regenerates a stale project file and leaves it STAGED for a commit that
# is not in the sequence, and scripts/test-all.sh does not regenerate the copy documents at all, it names
# what moved and stops (#1994). A remedy naming a step that does not change the state the reader is stuck
# in leaves them pressing the same control with no way to learn why (L111).
assert_contains "the staged regeneration is part of the sequence, not a surprise after it" \
  "${OUTPUT}" "git commit"
assert_contains "and the suite is described as judging the generated files rather than fixing them" \
  "${OUTPUT}" "does not regenerate"
assert_contains "with the command that does regenerate the copy inventory" \
  "${OUTPUT}" "TEST_RUNNER_REGENERATE_COPY_INVENTORY"
assert_not_contains "and it is not described as a conflict somebody has to resolve" \
  "${OUTPUT}" "This is the real kind"
assert_equals "the trial merge asked about current main against the branch" \
  "origin/main origin/feature-generated" "$(cat "${TRIAL_MERGE_LOG}")"

# --- #3210: a trial merge that could not RUN refuses, and says so in its own words ---
# A merge git REFUSED to attempt and one it attempted and resolved leave the same empty list of
# conflicted files. Reading the first as the second would wave a PR through on no evidence at all,
# so the unmeasured case refuses exactly as before and names itself rather than borrowing either
# verdict (L98, L11).
reset_stubs
TRIAL_MERGE_RESULT="${TRIAL_MERGE_UNMEASURED}"
TRIAL_MERGE_OUTPUT=""
resolve_pr() { PR_NUMBER="47"; PR_BRANCH="feature-unmeasured"; PR_MERGEABLE="CONFLICTING"; PR_BODY="${COMPLETE_PR_BODY}"; }
setup_worktree() { SETUP_CALLED="$1"; WORKTREE_DIR="/fake/worktree-unmeasured"; }
run_full_suite() { SUITE_RAN="yes"; return 0; }
release_verify_slot() { RELEASE_CALLED="yes"; }
merge_pr() { MERGE_CALLED="$1"; }

OUTPUT="$(verify_and_merge "47" 2>&1)"
assert_equals "an unmeasured trial merge never sets up a worktree" "" "${SETUP_CALLED}"
assert_equals "an unmeasured trial merge never merges" "" "${MERGE_CALLED}"
assert_contains "and it says which kind of collision it is was never measured" \
  "${OUTPUT}" "could not be measured"
assert_not_contains "an unmeasured answer never claims a file collided" "${OUTPUT}" "This is the real kind"
assert_not_contains "and never claims the collision is the harmless kind either" "${OUTPUT}" "This is the cheap kind"

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
# Re-sourcing restored the REAL gate and the real commit step too, and both would reach for a worktree
# path and an origin that do not exist here, so they are stubbed again alongside the rest (#2812).
gate_branch_project_freshness() { shift; GATED_REFS="$*"; return "${GATE_RESULT}"; }
commit_merge_regeneration() { return "${COMMIT_REGEN_RESULT}"; }
resolve_pr() { PR_NUMBER="45"; PR_BRANCH="feature-tidy"; PR_MERGEABLE="MERGEABLE"; PR_BODY="${COMPLETE_PR_BODY}"; }
setup_worktree() { SETUP_CALLED="$1"; WORKTREE_DIR="/fake/worktree-4"; }
combine_with_main() { COMBINE_CALLED="$1"; return 0; }
run_full_suite() { return 0; }
release_verify_slot() { RELEASE_CALLED="yes"; }
# Answers both calls merge_pr makes: the merge itself, and the state question that confirms it. A
# no-op stub (what stood here) now means "the PR is unreadable", which is correctly not a merge.
gh_as_danwright32() {
  case "${2:-}" in
    view) printf 'MERGED' ;;
    *) return 0 ;;
  esac
}
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
release_verify_slot() { RELEASE_CALLED="yes"; }
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

# --- #2601: the verify worktree is PERSISTENT, so its build cache stays warm between runs ---
# Xcode keys DerivedData by workspace path. The old throwaway-path-per-verification design paid a
# full cold build every time (75s measured against a warm run, 2026-08-12) and minted a ~1.6 GB
# build folder per run that needed its own cleanup (#2585). These cases drive the REAL
# setup_worktree and release_verify_slot against throwaway git repos, because the properties worth
# testing are the ones the stubs above cannot see: the path is FIXED, whatever a previous run (or
# its crash) left behind is scrubbed back to a fresh checkout, the slot is locked while in use, and
# nothing deletes the build cache any more.
#
# Sourcing the script again FIRST, deliberately: the cases above replaced these functions with
# stubs, and a stub is what these cases would otherwise call. They would then pass on the real
# functions being deleted, which is the definition of a test that protects nothing (L1).
# shellcheck source=./verify-and-merge-branch.sh
source "${SCRIPT_DIR}/verify-and-merge-branch.sh"
set +e

# Canonicalised (`pwd -P`), because git records a worktree's REAL path: on macOS mktemp answers
# under /var/folders while git lists /private/var/folders, and the registration assertion below
# compares the two as strings.
FIX_ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/overture-verify-slot-fixture.XXXXXX")" && pwd -P)"
# Both knobs pointed into the fixture, so these cases are structurally unable to touch the real
# slot or the real lock a live verification could be holding (L2).
export OVERTURE_VERIFY_WORKTREE="${FIX_ROOT}/slot"
export OVERTURE_VERIFY_WORKTREE_LOCK="${FIX_ROOT}/slot.lock"

# A tiny origin with a main and a feature branch, and a clone whose `origin` remote points at it,
# standing in for the checkout this script normally runs from.
ORIGIN_BARE="${FIX_ROOT}/origin.git"
SEED="${FIX_ROOT}/seed"
git init -q --bare "${ORIGIN_BARE}"
git init -q -b main "${SEED}"
echo "main-content" > "${SEED}/file.txt"
git -C "${SEED}" add file.txt
git -C "${SEED}" -c user.name=fixture -c user.email=fixture@localhost commit -qm main-one
git -C "${SEED}" branch feature
git -C "${SEED}" push -q "${ORIGIN_BARE}" main feature
CLONE="${FIX_ROOT}/clone"
git clone -q "${ORIGIN_BARE}" "${CLONE}"
REPO_ROOT="${CLONE}"

WORKTREE_DIR=""
setup_worktree "feature" >/dev/null 2>&1
assert_equals "the verify worktree lives at one fixed path" "${FIX_ROOT}/slot" "${WORKTREE_DIR}"
assert_equals "the slot holds the branch tip" \
  "$(git -C "${ORIGIN_BARE}" rev-parse feature)" \
  "$(git -C "${FIX_ROOT}/slot" rev-parse HEAD 2>/dev/null)"

# The slot is LOCKED between setup and release, because two verifications sharing one path would
# scrub each other mid-suite. Asked from a separate process, since the fixture itself is the holder.
if flock -n "${OVERTURE_VERIFY_WORKTREE_LOCK}" true 2>/dev/null; then
  fail "the slot lock must be held between setup and release"
else
  pass "the slot lock is held between setup and release"
fi
release_verify_slot
if flock -n "${OVERTURE_VERIFY_WORKTREE_LOCK}" true 2>/dev/null; then
  pass "release_verify_slot frees the slot lock"
else
  fail "release_verify_slot must free the slot lock"
fi

# Reuse must equal a FRESH checkout: whatever the previous verification (or its crash) left in the
# slot, the next one starts from exactly the branch tip and nothing else.
echo "leftover" > "${FIX_ROOT}/slot/untracked.txt"
echo "tampered" >> "${FIX_ROOT}/slot/file.txt"
setup_worktree "main" >/dev/null 2>&1
assert_equals "the second verification reuses the same path (which is what keeps the cache warm)" \
  "${FIX_ROOT}/slot" "${WORKTREE_DIR}"
assert_equals "the slot moved to the new branch tip" \
  "$(git -C "${ORIGIN_BARE}" rev-parse main)" \
  "$(git -C "${FIX_ROOT}/slot" rev-parse HEAD 2>/dev/null)"
if [[ -e "${FIX_ROOT}/slot/untracked.txt" ]]; then
  fail "a leftover untracked file must be scrubbed before the suite judges anything"
else
  pass "a leftover untracked file is scrubbed"
fi
assert_equals "a leftover edit to a tracked file is scrubbed" \
  "main-content" "$(cat "${FIX_ROOT}/slot/file.txt" 2>/dev/null)"
release_verify_slot

# A busy slot is WAITED for, and out loud (L110): a silent wait is indistinguishable from a hang
# for however long the other verification takes.
flock "${OVERTURE_VERIFY_WORKTREE_LOCK}" sleep 1 &
LOCK_HOLDER=$!
sleep 0.3
WAIT_OUTPUT="$( { setup_worktree "feature" >/dev/null; } 2>&1 )"
WAIT_STATUS=$?
wait "${LOCK_HOLDER}" 2>/dev/null
assert_equals "a busy slot is waited for, and setup still succeeds" "0" "${WAIT_STATUS}"
assert_contains "the wait announces itself rather than sitting silent" "${WAIT_OUTPUT}" "waiting"

# A completed verification leaves the slot checkout, its registration, and its build cache all in
# place. The cache IS the speedup, and reclaim-orphan-derived-data.sh keeps any folder whose
# workspace still exists, so the slot persisting is also what protects the cache from the sweep.
DERIVED_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/verify-derived-data.XXXXXX")"
write_derived_folder() {
  local name="$1" workspace="$2"
  mkdir -p "${DERIVED_ROOT}/${name}"
  cat > "${DERIVED_ROOT}/${name}/info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>WorkspacePath</key>
	<string>${workspace}</string>
</dict>
</plist>
PLIST
}
write_derived_folder "Overture-slot" "${FIX_ROOT}/slot/mac/Overture.xcodeproj"
export XCODE_DERIVED_DATA_ROOT="${DERIVED_ROOT}"

reset_stubs
resolve_pr() { PR_NUMBER="60"; PR_BRANCH="feature"; PR_MERGEABLE="MERGEABLE"; PR_BODY="${COMPLETE_PR_BODY}"; }
run_full_suite() { return 0; }
merge_pr() { MERGE_CALLED="$1"; }

verify_and_merge "60" >/dev/null 2>&1
assert_equals "the end-to-end run merged its PR" "60" "${MERGE_CALLED}"
if [[ -d "${FIX_ROOT}/slot" ]]; then
  pass "the slot survives a completed verification"
else
  fail "the slot must survive a completed verification"
fi
if grep -qF "worktree ${FIX_ROOT}/slot" <<< "$(git -C "${CLONE}" worktree list --porcelain)"; then
  pass "the slot stays registered as a worktree"
else
  fail "the slot must stay registered as a worktree"
fi
if [[ -d "${DERIVED_ROOT}/Overture-slot" ]]; then
  pass "the warm build cache survives the verification (deleting it was the old behaviour)"
else
  fail "the warm build cache must survive the verification"
fi
if flock -n "${OVERTURE_VERIFY_WORKTREE_LOCK}" true 2>/dev/null; then
  pass "the slot lock is released when the verification ends"
else
  fail "the slot lock must be released when the verification ends"
fi

unset XCODE_DERIVED_DATA_ROOT OVERTURE_VERIFY_WORKTREE OVERTURE_VERIFY_WORKTREE_LOCK
rm -rf "${DERIVED_ROOT}" "${FIX_ROOT}"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All verify-and-merge-branch.sh fixtures passed."
  exit 0
else
  echo "${FAILURES} verify-and-merge-branch.sh fixture(s) failed."
  exit 1
fi
