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

# One cleanup for everything this file creates, and ONE trap. Bash keeps a single EXIT trap, so a second
# `trap ... EXIT` added later silently replaces the first and whatever it removed starts leaking; that is
# how eval-prep-runbook.test.sh leaked a file per run for days.
fixture_cleanup() {
  rm -f "${BATCH_OUT_FILE}"
  rm -rf "${FIX_ROOT:-}" "${HOOK_ROOT:-}"
}
trap fixture_cleanup EXIT

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
COMPLETE_PR_BODY='Writers: none new. Readers: none new. Siblings: swept. Guards seen to fail: yes. Premise re-checked: held.'

reset_stubs() {
  SUITE_RUNS=0
  SETUP_BRANCH=""
  COMBINED_BRANCHES=""
  MERGED=""
  RELEASE_CALLED=""
  MERGE_RESULTS=()
  GATED_REFS=""
  GATE_RESULT=0
  # #2812's per-ref freshness gate, stubbed here rather than in every case: unstubbed it would fetch
  # from the REAL origin and run xcodegen against a worktree path these cases invented.
  gate_branch_project_freshness() { shift; GATED_REFS="$*"; return "${GATE_RESULT}"; }
  # #3210's trial merge, stubbed for reset_stubs' usual reason: unstubbed it would fetch from the REAL
  # origin and merge refs these cases invented. The default keeps the pre-#3210 cases meaning what they
  # were written to mean, a CONFLICTING PR refusing the whole batch.
  TRIAL_MERGE_RESULT="${TRIAL_MERGE_CONFLICTS}"
  fetch_trial_merge_refs() { return 0; }
  trial_merge_conflicts() { printf 'docs/contracts.md\n'; return "${TRIAL_MERGE_RESULT}"; }
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
# #2812: main is judged too, not only the branches. The regeneration committed between combines is only
# honest if EVERY side that goes into the tree was fresh on its own tip first.
assert_eq "main and every branch have their own project file judged before anything is merged" \
  "main branch-11 branch-12 branch-13" "${GATED_REFS}"

# --- #2812: a ref carrying a stale project file refuses the batch before anything expensive ---
# Without this, commit_merge_regeneration would be a free pass: a branch whose own project file is stale
# would have it silently regenerated in the verify worktree, the gate would pass on a file this script
# wrote, and the stale one would still be what lands on main. That is #1368, exactly.
reset_stubs
stub_resolve
GATE_RESULT=1
setup_worktree() { SETUP_BRANCH="$1"; WORKTREE_DIR="/fake/worktree"; }
combine_branches() { shift; COMBINED_BRANCHES="$*"; return 0; }
run_full_suite() { SUITE_RUNS=$((SUITE_RUNS + 1)); return 0; }
release_verify_slot() { RELEASE_CALLED="yes"; }
merge_pr() { MERGED="${MERGED}${1} "; return 0; }

run_batch "91" "92"
assert_eq "a stale project file on any ref is never combined over" "" "${COMBINED_BRANCHES}"
assert_eq "a stale project file on any ref costs no suite run" "0" "${SUITE_RUNS}"
assert_eq "a stale project file on any ref merges nothing" "" "${MERGED}"
assert_eq "the slot is released when the freshness gate refuses" "yes" "${RELEASE_CALLED}"
assert_eq "a refused freshness gate reports failure" "1" "${BATCH_STATUS}"
assert_contains "and says nothing was verified" "${BATCH_OUTPUT}" "Nothing was verified"

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

# --- #3210: a collision this repo's own merge resolves refuses the batch with a DIFFERENT reason ---
# The batch is where the mystery costs the most: it refuses every PR named alongside the flagged one,
# so a reader has to know in seconds whether the fix is a mechanical branch update or somebody's
# decision. It still refuses (GitHub will not merge a CONFLICTING PR whatever this Mac resolves), and
# the change is that it says which kind and hands over the commands.
reset_stubs
TRIAL_MERGE_RESULT="${TRIAL_MERGE_RESOLVED}"
resolve_pr() {
  PR_NUMBER="$1"
  PR_BRANCH="branch-$1"
  PR_BODY="${COMPLETE_PR_BODY}"
  if [[ "$1" == "52" ]]; then PR_MERGEABLE="CONFLICTING"; else PR_MERGEABLE="MERGEABLE"; fi
}
setup_worktree() { SETUP_BRANCH="$1"; WORKTREE_DIR="/fake/worktree"; }
combine_branches() { COMBINED_BRANCHES="$*"; return 0; }
run_full_suite() { SUITE_RUNS=$((SUITE_RUNS + 1)); return 0; }
release_verify_slot() { RELEASE_CALLED="yes"; }
merge_pr() { MERGED="${MERGED}${1} "; return 0; }

BATCH_OUTPUT="$(verify_and_merge_batch "51" "52" "53" 2>&1)"
assert_eq "a collision this repo resolves still costs no suite run" "0" "${SUITE_RUNS}"
assert_eq "and still merges nothing in the batch" "" "${MERGED}"
assert_contains "the reader is told which of the two kinds it is" "${BATCH_OUTPUT}" "This is the cheap kind"
assert_contains "and which branch to bring up to main" "${BATCH_OUTPUT}" "branch-52"

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
if grep -q . <<< "$(git -C "${WORK}" ls-files --unmerged)"; then
  fail "the conflicted merge must be aborted, leaving no half-merged tree behind"
else
  pass "the conflicted merge is aborted, so no suite can be run over a half-merged tree"
fi

git -C "${CLONE}" worktree remove --force "${WORK}" >/dev/null 2>&1
rm -rf "${FIX_ROOT}"

echo
echo "--- #2812: the post-merge hook's regeneration, between combines ---"

# The case above uses branches that touch different files and no hook, so it never meets the state that
# broke the batch path for real on 2026-08-16 combining #2809 and #2810: this repo's own post-merge hook
# regenerates mac/Overture.xcodeproj/project.pbxproj after a merge and leaves it STAGED, and the NEXT
# merge into that worktree dies with "Your local changes to the following files would be overwritten by
# merge". Two branches that each add a Swift file is the ordinary case, so the batch gave up exactly
# where it saves the most.
#
# So this section builds an Overture-SHAPED throwaway repo: the same .gitattributes entry sending the
# project file to the REAL merge driver (which keeps one side and does not regenerate, so the merged
# tree's project file is stale by construction), and a miniature of the real post-merge hook that
# regenerates that file from the tree and stages it when it moved. Miniature rather than the real hook
# because the real one runs xcodegen over a real Xcode project; what matters to this script is only that
# something stages a generated file after a merge, which is exactly what it does.

HOOK_ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/overture-batch-2812.XXXXXX")" && pwd -P)"
HOOK_ORIGIN="${HOOK_ROOT}/origin.git"
HOOK_SEED="${HOOK_ROOT}/seed"
PBX_REL="mac/Overture.xcodeproj/project.pbxproj"

seed_commit() { git -C "${HOOK_SEED}" -c user.name=fixture -c user.email=fixture@localhost "$@"; }

git init -q --bare "${HOOK_ORIGIN}"
git init -q -b main "${HOOK_SEED}"
mkdir -p "${HOOK_SEED}/mac/Overture.xcodeproj" "${HOOK_SEED}/scripts"
printf '%s merge=overture-generated\n' "${PBX_REL}" > "${HOOK_SEED}/.gitattributes"
printf 'Base.swift\n' > "${HOOK_SEED}/${PBX_REL}"
: > "${HOOK_SEED}/mac/Base.swift"
printf 'one\ntwo\nthree\n' > "${HOOK_SEED}/shared.txt"

# A stand-in for scripts/check-pbxproj-fresh.sh with the SAME contract the real one publishes (0 fresh,
# 1 BLOCK, 2 cannot verify), so the gate below is driven through every one of its branches without an
# xcodegen or a real Xcode project. The real script's own verdicts are its own fixture's subject
# (scripts/check-pbxproj-fresh.test.sh); what is under test here is what this script DOES with each.
cat > "${HOOK_SEED}/scripts/check-pbxproj-fresh.sh" <<'FRESH'
#!/usr/bin/env bash
dir="${1:-.}"
if [ -f "${dir}/mac/CANNOT-VERIFY" ]; then
  echo "check-pbxproj-fresh: cannot verify: xcodegen version mismatch (stand-in)." >&2
  exit 2
fi
if [ -f "${dir}/mac/STALE" ]; then
  echo "check-pbxproj-fresh: BLOCK: mac/Overture.xcodeproj/project.pbxproj is stale (stand-in)." >&2
  exit 1
fi
exit 0
FRESH
chmod +x "${HOOK_SEED}/scripts/check-pbxproj-fresh.sh"
seed_commit add -A
seed_commit commit -qm base
seed_commit branch base-point

# main moves on, so both sides of every merge below have touched the generated file since the merge
# base. That is what makes the driver keep one side and leaves the merged tree stale.
: > "${HOOK_SEED}/mac/Main.swift"
printf 'Base.swift\nMain.swift\n' > "${HOOK_SEED}/${PBX_REL}"
seed_commit add -A
seed_commit commit -qm main-two

# The ordinary case: two branches that each add a Swift file and each regenerate their own project file.
for pair in "feat-a:A" "feat-b:B"; do
  seed_commit checkout -q base-point
  seed_commit checkout -q -b "${pair%%:*}"
  : > "${HOOK_SEED}/mac/${pair#*:}.swift"
  printf '%s.swift\nBase.swift\n' "${pair#*:}" > "${HOOK_SEED}/${PBX_REL}"
  seed_commit add -A
  seed_commit commit -qm "${pair%%:*}"
done

# A branch whose own project file is stale on its own tip, which must still be refused: regenerating on
# top of it here would hide exactly the staleness #1368 exists to catch.
seed_commit checkout -q base-point
seed_commit checkout -q -b feat-stale
: > "${HOOK_SEED}/mac/S.swift"
: > "${HOOK_SEED}/mac/STALE"
seed_commit add -A
seed_commit commit -qm feat-stale

# A branch whose freshness cannot be JUDGED at all (the real script's exit 2: a xcodegen version
# mismatch, or no xcodegen). A different fact from staleness, and only one of the two is somebody's
# mistake, so the two must not share a message (L11).
seed_commit checkout -q base-point
seed_commit checkout -q -b feat-unverifiable
: > "${HOOK_SEED}/mac/U.swift"
: > "${HOOK_SEED}/mac/CANNOT-VERIFY"
seed_commit add -A
seed_commit commit -qm feat-unverifiable

# Two branches rewriting the same line of a file that is NOT generated: a real conflict, which must go
# on being refused with the hook installed.
for pair in "hook-clash-a:A" "hook-clash-b:B"; do
  seed_commit checkout -q base-point
  seed_commit checkout -q -b "${pair%%:*}"
  printf 'one\n%s\nthree\n' "${pair#*:}" > "${HOOK_SEED}/shared.txt"
  seed_commit commit -aqm "${pair%%:*}"
done

seed_commit checkout -q main
seed_commit push -q "${HOOK_ORIGIN}" main feat-a feat-b feat-stale feat-unverifiable hook-clash-a hook-clash-b
git -C "${HOOK_ORIGIN}" symbolic-ref HEAD refs/heads/main

HOOK_CLONE="${HOOK_ROOT}/clone"
git clone -q "${HOOK_ORIGIN}" "${HOOK_CLONE}"
# The REAL merge driver, registered the way scripts/install-git-hooks.sh registers it. It keeps one side
# and deliberately does not regenerate, which is what leaves the merged tree's project file stale.
git -C "${HOOK_CLONE}" config merge.overture-generated.driver \
  "bash '${SCRIPT_DIR}/lib/merge-generated.sh' %O %A %B %L %P"

cat > "${HOOK_CLONE}/.git/hooks/post-merge" <<HOOK
#!/usr/bin/env bash
set -uo pipefail
PBX="${PBX_REL}"
CHANGED="\$(git diff --name-only ORIG_HEAD HEAD 2>/dev/null || true)"
case "\${CHANGED}" in *mac/*) ;; *) exit 0 ;; esac
( cd mac && ls *.swift 2>/dev/null | sort ) > "\${PBX}"
git diff --quiet -- "\${PBX}" && exit 0
git add -- "\${PBX}"
echo "post-merge: regenerated and STAGED \${PBX}" >&2
exit 0
HOOK
chmod +x "${HOOK_CLONE}/.git/hooks/post-merge"

REPO_ROOT="${HOOK_CLONE}"
HOOK_WORK="${HOOK_ROOT}/work"
git -C "${HOOK_CLONE}" worktree add -q --detach "${HOOK_WORK}" origin/main

# The reproduction. Before #2812 this returned 1 on the SECOND branch, with git refusing the merge over
# the staged regeneration, so the batch verified nothing and merged nothing.
HOOK_COMBINE_OUTPUT="$(combine_branches "${HOOK_WORK}" "feat-a" "feat-b" 2>&1)"
HOOK_COMBINE_STATUS=$?
assert_eq "two branches that each add a file combine even though the hook stages a regeneration" \
  "0" "${HOOK_COMBINE_STATUS}"
assert_not_contains "and the refusal that used to fire is not printed" \
  "${HOOK_COMBINE_OUTPUT}" "would be overwritten by merge"
if [[ -f "${HOOK_WORK}/mac/A.swift" && -f "${HOOK_WORK}/mac/B.swift" ]]; then
  pass "the combined tree holds both branches' work"
else
  fail "the combined tree must hold both branches' work"
fi
# What the hook staged is COMMITTED, not left in the index: an uncommitted change to a file the next
# merge also touches is the whole defect.
assert_empty "the combined worktree is left clean, with nothing staged" \
  "$(git -C "${HOOK_WORK}" status --porcelain)"
assert_eq "and the committed project file is the regeneration of the COMBINED tree" \
  "A.swift
B.swift
Base.swift
Main.swift" "$(git -C "${HOOK_WORK}" show "HEAD:${PBX_REL}")"

# A real conflict must still refuse, verifying nothing and merging nothing. The hook is installed for
# this one too, so what is being proved is that the fix did not turn the refusal into a resolution.
git -C "${HOOK_WORK}" checkout -q --force --detach origin/main
git -C "${HOOK_WORK}" clean -qffd
HOOK_CLASH_OUTPUT="$(combine_branches "${HOOK_WORK}" "hook-clash-a" "hook-clash-b" 2>&1)"
HOOK_CLASH_STATUS=$?
assert_eq "a genuine content conflict is still refused with the hook installed" "1" "${HOOK_CLASH_STATUS}"
assert_contains "the refusal names the branch that would not go in" "${HOOK_CLASH_OUTPUT}" "hook-clash-b"
assert_contains "and says nothing was verified" "${HOOK_CLASH_OUTPUT}" "Nothing was verified"
if grep -q . <<< "$(git -C "${HOOK_WORK}" ls-files --unmerged)"; then
  fail "the conflicted merge must be aborted, leaving no half-merged tree behind"
else
  pass "the conflicted merge is aborted, so no suite can be run over a half-merged tree"
fi


# --- the per-ref freshness gate, against the same throwaway repos ---
# The gate is what keeps the commit above from being a free pass, so it is worth proving on real refs
# rather than only through a stub: a stale ref is refused, a set of fresh ones is not, and the worktree
# comes back on the commit the gate found it on either way.
git -C "${HOOK_WORK}" checkout -q --force --detach origin/main
git -C "${HOOK_WORK}" clean -qffd
HOOK_MAIN_SHA="$(git -C "${HOOK_CLONE}" rev-parse origin/main)"

gate_branch_project_freshness "${HOOK_WORK}" "main" "feat-a" "feat-b" >/dev/null 2>&1
assert_eq "refs whose own project file is fresh on their own tip pass the gate" "0" "$?"
assert_eq "and the worktree is left on the commit the gate found it on" \
  "${HOOK_MAIN_SHA}" "$(git -C "${HOOK_WORK}" rev-parse HEAD)"

GATE_STALE_OUTPUT="$(gate_branch_project_freshness "${HOOK_WORK}" "main" "feat-stale" "feat-a" 2>&1)"
GATE_STALE_STATUS=$?
assert_eq "a ref carrying a stale project file on its own tip is refused" "1" "${GATE_STALE_STATUS}"
assert_contains "the refusal names the ref" "${GATE_STALE_OUTPUT}" "feat-stale carries a stale"
assert_contains "and says regenerating it here would only hide what lands on main" \
  "${GATE_STALE_OUTPUT}" "#1368"
assert_eq "the worktree is restored even when the gate refuses" \
  "${HOOK_MAIN_SHA}" "$(git -C "${HOOK_WORK}" rev-parse HEAD)"

GATE_UNVERIFIABLE_OUTPUT="$(gate_branch_project_freshness "${HOOK_WORK}" "feat-unverifiable" 2>&1)"
assert_eq "a ref whose freshness cannot be judged is also refused" "1" "$?"
assert_contains "but it is told apart from staleness" "${GATE_UNVERIFIABLE_OUTPUT}" "Cannot judge"
assert_not_contains "and is never reported as a stale file, which is a different fact" \
  "${GATE_UNVERIFIABLE_OUTPUT}" "carries a stale"

# --- what the commit will NOT do: anything the post-merge hook does not own ---
git -C "${HOOK_WORK}" checkout -q --force --detach origin/main
echo "hand written" > "${HOOK_WORK}/shared.txt"
git -C "${HOOK_WORK}" add shared.txt
STRAY_OUTPUT="$(commit_merge_regeneration "${HOOK_WORK}" 2>&1)"
STRAY_STATUS=$?
assert_eq "a staged path the hook does not own is refused, not committed" "1" "${STRAY_STATUS}"
assert_contains "and the refusal names it" "${STRAY_OUTPUT}" "shared.txt"
assert_eq "nothing is committed when it refuses" \
  "${HOOK_MAIN_SHA}" "$(git -C "${HOOK_WORK}" rev-parse HEAD)"
git -C "${HOOK_WORK}" reset -q --hard origin/main

# The list of paths this commits is checked against the hook that STAGES them, rather than repeated from
# memory, because a hand-written registry only ever checks what somebody remembered (L96).
assert_eq "exactly one generated file is committed between combines" \
  "1" "${#MERGE_REGENERATION_PATHS[@]}"
assert_contains "and it is the file scripts/hooks/post-merge stages" \
  "$(cat "${SCRIPT_DIR}/hooks/post-merge")" "${MERGE_REGENERATION_PATHS[0]}"

# --- the verify slot this fixture uses is a throwaway one, never the shared path ---
# The real slot at ~/.overture-verify-worktree is in use by real verifications of real PRs. An edit that
# stopped honouring the override would send a test run straight into one, so that is asserted here
# rather than left to whoever reads the script.
export OVERTURE_VERIFY_WORKTREE="${HOOK_ROOT}/slot"
export OVERTURE_VERIFY_WORKTREE_LOCK="${HOOK_ROOT}/slot.lock"
setup_worktree "main" >/dev/null 2>&1
assert_eq "setup_worktree honours OVERTURE_VERIFY_WORKTREE" "${HOOK_ROOT}/slot" "${WORKTREE_DIR}"
assert_not_contains "so no fixture run reaches the shared slot a real verification holds" \
  "${WORKTREE_DIR}" ".overture-verify-worktree"
if [[ -f "${OVERTURE_VERIFY_WORKTREE_LOCK}" ]]; then
  pass "and the lock it holds is the overridden one"
else
  fail "the overridden lock file must be the one setup_worktree opened"
fi
release_verify_slot
git -C "${HOOK_CLONE}" worktree remove --force "${HOOK_ROOT}/slot" >/dev/null 2>&1
unset OVERTURE_VERIFY_WORKTREE OVERTURE_VERIFY_WORKTREE_LOCK

git -C "${HOOK_CLONE}" worktree remove --force "${HOOK_WORK}" >/dev/null 2>&1
rm -rf "${HOOK_ROOT}"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All verify-and-merge-batch.sh fixtures passed."
  exit 0
else
  echo "${FAILURES} verify-and-merge-batch.sh fixture(s) failed."
  exit 1
fi
