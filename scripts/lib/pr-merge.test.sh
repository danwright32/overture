#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501).
# shellcheck source=./shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shell-assertions.sh"

# Coverage for scripts/lib/pr-merge.sh's merge_pr (#2602): merge, then confirm with GitHub that the PR
# really reached MERGED, and do nothing else at all unless it did.
#
# Drives the REAL merge_pr with only the gh wrapper replaced, since that is the one thing that must not
# run for real here. The two branch-level scripts' own fixtures cover the decision to CALL it; this file
# covers what it does, and the last case covers the property that there is only one of it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

REPO="danwright32/overture"
# shellcheck source=./pr-merge.sh
source "${SCRIPT_DIR}/pr-merge.sh"
set +e

FAILURES=0

# --- a merge gh REFUSES must not report success, and must destroy nothing ------------------------------
#
# Measured 2026-08-13, the first real run of verify-and-merge-batch.sh: `gh pr merge 2609` exited 1 with
# `GraphQL: Something went wrong while executing your query`, a transient GitHub fault. Every line after
# the merge call ran anyway, the last two end in `|| true`, and so merge_pr returned 0: the run printed
# `merged   PR #2609`, deleted the local branch of a PR that was still open, and exited 0. Errexit could
# not save it, because both callers invoke merge_pr from a context where errexit is suspended.
#
# These cases drive the REAL merge_pr with only the gh wrapper replaced, which is the one thing that must
# not run for real here.
# The recorded gh subcommands go to a FILE, not a variable: merge_pr reads the state through a command
# substitution, whose subshell would discard any assignment made inside it, so a variable could only ever
# record the merge call and would leave the state question looking as though it never happened.
GH_CALL_LOG="$(mktemp "${TMPDIR:-/tmp}/gh-calls.XXXXXX")"

# The lessons review merge_pr asks before merging (claude-config#560) is a seam, set for every case
# here, so no case reaches the real ~/.claude checker (L284). Cases about the merge itself get one that
# allows; the gate's own cases below set their own.
FAKE_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pr-review-check.XXXXXX")"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/calls"\necho "review allows"\nexit 0\n' "${FAKE_CHECK_DIR}" > "${FAKE_CHECK_DIR}/allow.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/calls"\necho "Refusing to merge yet: the lessons review is still running"\nexit 1\n' "${FAKE_CHECK_DIR}" > "${FAKE_CHECK_DIR}/refuse.sh"
export PR_REVIEW_CHECK="${FAKE_CHECK_DIR}/allow.sh"
merge_refusal_out() {
  local merge_rc="$1" reported_state="$2"
  LOCAL_BRANCH_DELETED=""
  : > "${GH_CALL_LOG}"
  gh_as_danwright32() {
    echo "$2" >> "${GH_CALL_LOG}"
    case "$2" in
      merge) return "${merge_rc}" ;;
      # The head question the lessons review gate asks first is not the state question these cases
      # are about, so it always has an answer.
      # The queue engine gate's files question (#4358 slice E4d) answers a file outside the engine, so these
      # cases are about the merge rather than the gate, which has its own cases below.
      view) case "$*" in *headRefOid*) printf 'abc1234\tmain' ;; *files*) printf 'scripts/lib/scratch.sh' ;;
                         *) printf '%s' "${reported_state}" ;; esac ;;
    esac
  }
  delete_merged_local_branch() { LOCAL_BRANCH_DELETED="$1"; }
  MERGE_PR_RC=0
  merge_pr "90" "feature-refused" 2>&1 || MERGE_PR_RC=$?
}

OUT="$(merge_refusal_out 1 "MERGED"; echo "RC=${MERGE_PR_RC}"; echo "DELETED=${LOCAL_BRANCH_DELETED}")"
assert_contains "a merge gh refuses reports failure" "${OUT}" "RC=1"
assert_contains "and says gh is what refused" "${OUT}" "gh refused to merge PR #90"
assert_contains "and deletes no local branch" "${OUT}" "DELETED="
assert_not_contains "and does not delete the branch of a PR that never merged" "${OUT}" "DELETED=feature-refused"

# The half that a status code alone cannot catch: gh exits 0 but the PR is not actually merged. The claim
# the caller acts on is "this PR reached MERGED", so that is the claim that gets checked (L12).
OUT="$(merge_refusal_out 0 "OPEN"; echo "RC=${MERGE_PR_RC}"; echo "DELETED=${LOCAL_BRANCH_DELETED}")"
assert_contains "a PR still OPEN after a successful merge command reports failure" "${OUT}" "RC=1"
assert_contains "and says what state it actually read" "${OUT}" "reads as OPEN rather than MERGED"
assert_not_contains "and deletes nothing" "${OUT}" "DELETED=feature-refused"

# An unreadable state is not a pass either: it is the same not-confirmed case, said differently.
OUT="$(merge_refusal_out 0 ""; echo "RC=${MERGE_PR_RC}")"
assert_contains "an unreadable PR state reports failure" "${OUT}" "RC=1"
assert_contains "and says it could not be read" "${OUT}" "unreadable"

# And the happy path still works: gh merges, GitHub confirms MERGED, the local branch is tidied.
OUT="$(merge_refusal_out 0 "MERGED"; echo "RC=${MERGE_PR_RC}"; echo "DELETED=${LOCAL_BRANCH_DELETED}")"
GH_CALLS="$(tr '\n' ' ' < "${GH_CALL_LOG}")"
assert_contains "a confirmed merge reports success" "${OUT}" "RC=0"
assert_contains "and tidies the local branch" "${OUT}" "DELETED=feature-refused"
assert_contains "and it asked GitHub for the state rather than assuming it" "${GH_CALLS}" "view"

# --- #3187: a decision quoted in the body is recorded on the issue, and only after a real merge --------
#
# It rides on merge_pr rather than on either caller, so all three merge paths get it from one place, and
# it sits with the other things that must not happen unless the PR really reached MERGED. A call recorded
# for a PR that never landed is a decision nobody made, sitting on the issue looking exactly like one
# somebody did.
DECISION_RECORDED=""
record_pr_decision() { DECISION_RECORDED="$1"; }

OUT="$(merge_refusal_out 0 "MERGED"; echo "RECORDED=${DECISION_RECORDED}")"
assert_contains "a confirmed merge records the decision its body quoted" "${OUT}" "RECORDED=90"

OUT="$(merge_refusal_out 1 "MERGED"; echo "RECORDED=${DECISION_RECORDED}")"
assert_contains "a refused merge records nothing" "${OUT}" "RECORDED="
assert_not_contains "and specifically does not record the PR it failed to merge" "${OUT}" "RECORDED=90"

OUT="$(merge_refusal_out 0 "OPEN"; echo "RECORDED=${DECISION_RECORDED}")"
assert_not_contains "a PR still OPEN records nothing either" "${OUT}" "RECORDED=90"

# --- claude-config#560: the lessons review of the whole branch is asked BEFORE the merge ---------------
#
# merge_pr is the one merge in this repo, called from verify-and-merge-branch.sh and -batch.sh as well as
# merge-when-green.sh, and the session's merge gate only sees a command typed as a merge. So the
# review's verdict is asked here, where every route passes, by the same checker the gate uses.
gate_out() {  # gate_out <checker path or MISSING> [SKIP]
  : > "${GH_CALL_LOG}"; rm -f "${FAKE_CHECK_DIR}/calls"
  gh_as_danwright32() {
    echo "$2" >> "${GH_CALL_LOG}"
    case "$*" in
      *headRefOid*) printf 'abc1234\tmain' ;;
      *merge*) return 0 ;;
      *view*) printf 'MERGED' ;;
    esac
  }
  delete_merged_local_branch() { :; }
  local checker="$1"
  [[ "${checker}" == "MISSING" ]] && checker="${FAKE_CHECK_DIR}/does-not-exist.sh"
  MERGE_PR_RC=0
  PR_REVIEW_CHECK="${checker}" SKIP_PR_REVIEW="${2:-}" merge_pr "91" "feature-gated" 2>&1 || MERGE_PR_RC=$?
}
OUT="$(gate_out "${FAKE_CHECK_DIR}/refuse.sh"; echo "RC=${MERGE_PR_RC}"; echo "GH=$(tr '\n' ' ' < "${GH_CALL_LOG}")")"
assert_contains "a review that refuses stops the merge" "${OUT}" "RC=1"
assert_contains "and its words reach the caller" "${OUT}" "still running"
assert_not_contains "and gh was never asked to merge" "${OUT}" "GH=view merge"
assert_contains "the checker was asked about the pull request's head, not the local one" "$(cat "${FAKE_CHECK_DIR}/calls" 2>/dev/null)" "--sha abc1234"
assert_contains "and against its base branch" "$(cat "${FAKE_CHECK_DIR}/calls" 2>/dev/null)" "--base-ref origin/main"

OUT="$(gate_out "${FAKE_CHECK_DIR}/allow.sh"; echo "RC=${MERGE_PR_RC}"; echo "GH=$(tr '\n' ' ' < "${GH_CALL_LOG}")")"
assert_contains "a review that allows lets the merge run" "${OUT}" "RC=0"
assert_contains "and gh merged" "${OUT}" "merge"
# The merge is pinned to the commit the review read, so a push landing between the check and the
# merge is refused by GitHub rather than merged unreviewed (L179; found by the first real review).
gh_args_out() {
  : > "${GH_CALL_LOG}"
  gh_as_danwright32() {
    printf '%s\n' "$*" >> "${GH_CALL_LOG}"
    case "$*" in *headRefOid*) printf 'abc1234\tmain' ;; *"pr merge"*) return 0 ;; *view*) printf 'MERGED' ;; esac
  }
  delete_merged_local_branch() { :; }
  PR_REVIEW_CHECK="${FAKE_CHECK_DIR}/allow.sh" SKIP_PR_REVIEW="" merge_pr "92" "feature-pinned" >/dev/null 2>&1
  grep "pr merge" "${GH_CALL_LOG}"
}
assert_contains "the merge is pinned to the head the review read" "$(gh_args_out)" "--match-head-commit abc1234"

# #4358 slice E4d: with the review skipped, the merge is still pinned, to the head the engine gate was asked about.
SKIPPED_HEAD="1111111111222222222233333333334444444444"
gh_args_skipped_out() {
  : > "${GH_CALL_LOG}"
  gh_as_danwright32() {
    printf '%s\n' "$*" >> "${GH_CALL_LOG}"
    case "$*" in
      *headRefOid*) printf '%s' "${SKIPPED_HEAD}" ;;
      *files*) printf 'docs/x.md' ;;
      *"pr merge"*) return 0 ;;
      *view*) printf 'MERGED' ;;
    esac
  }
  delete_merged_local_branch() { :; }
  PR_REVIEW_CHECK="${FAKE_CHECK_DIR}/does-not-exist.sh" SKIP_PR_REVIEW=1 merge_pr "93" "feature-skipped" >/dev/null 2>&1
  grep "pr merge" "${GH_CALL_LOG}"
}
assert_contains "a merge with the review skipped is pinned to the head the gate read" "$(gh_args_skipped_out)" \
  "--match-head-commit ${SKIPPED_HEAD}"

OUT="$(gate_out MISSING; echo "RC=${MERGE_PR_RC}"; echo "GH=$(tr '\n' ' ' < "${GH_CALL_LOG}")")"
assert_contains "a missing checker refuses rather than merging unread" "${OUT}" "RC=1"
assert_contains "and names the override" "${OUT}" "SKIP_PR_REVIEW=1"

OUT="$(gate_out MISSING 1; echo "RC=${MERGE_PR_RC}")"
assert_contains "the override lets the merge run" "${OUT}" "RC=0"
assert_contains "and says out loud that it did" "${OUT}" "NOT held for the lessons review"

rm -rf "${FAKE_CHECK_DIR}"
rm -f "${GH_CALL_LOG}"


# --- the queue engine's merge gate (#4358 slice E4d) ---------------------------------------------------
#
# engine_gate_allows, driven with the gh wrapper answering the PR's files and the run replaced
# (ENGINE_GATE_RUNNER), so no case reaches GitHub or the live store. Every outcome it names is produced here
# (L151): not an engine PR, a pass, a failed run, a run that printed no PASSED line (skipped), unreadable
# files, a head that is not a whole commit, and the override.
GATE_SHA="0123456789abcdef0123456789abcdef01234567"
GATE_RUNS="$(mktemp "${TMPDIR:-/tmp}/engine-gate-runs.XXXXXX")"
gate_files_out() {
  local files="$1" head="$2" runner="$3"
  : > "${GATE_RUNS}"
  gh_as_danwright32() { printf '%s' "${GATE_FILES}"; }
  GATE_FILES="${files}" ENGINE_GATE_RUNNER="${runner}" engine_gate_allows "93" "${head}" 2>&1
  echo "RC=$?"
  echo "RUNS=$(wc -l < "${GATE_RUNS}" | tr -d ' ')"
}
gate_passes() { echo "$1" >> "${GATE_RUNS}"; echo "noise"; echo "engine-divergence-gate: PASSED matches 5, records 0"; }
gate_fails() { echo "$1" >> "${GATE_RUNS}"; echo "the merge gate REFUSED: factMismatch x1"; return 1; }
gate_skipped() { echo "$1" >> "${GATE_RUNS}"; echo "Test theBranchsVerifier... skipped: no live store"; return 0; }

# engine_gate_run itself, over a throwaway repository whose runner is a stub committed at the head, so the run
# reaches no live store: its verdict and exit code come back, and the worktree and its temporary folder are gone
# afterwards on every exit, an interrupt included (the lessons review of E4d1, L114, L473).
GATE_REPO="$(mktemp -d "${TMPDIR:-/tmp}/engine-gate-repo.XXXXXX")"
GATE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/engine-gate-tmp.XXXXXX")"
gate_repo_commit() {  # gate_repo_commit <runner body>: commits the stub runner and prints the commit
  mkdir -p "${GATE_REPO}/mac/scripts"
  printf '#!/bin/bash\n%s\n' "$1" > "${GATE_REPO}/mac/scripts/run-tests-locked.sh"
  chmod +x "${GATE_REPO}/mac/scripts/run-tests-locked.sh"
  git -C "${GATE_REPO}" add -A >/dev/null
  git -C "${GATE_REPO}" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m stub >/dev/null
  git -C "${GATE_REPO}" rev-parse HEAD
}
git -C "${GATE_REPO}" init -q
gate_run_out() {  # gate_run_out <commit>: runs engine_gate_run against the throwaway repository
  local rc=0
  REPO_ROOT="${GATE_REPO}" TMPDIR="${GATE_TMP}" engine_gate_run "$1" 2>&1 || rc=$?
  echo "RC=${rc}"
  echo "WORKTREES=$(git -C "${GATE_REPO}" worktree list | wc -l | tr -d ' ')"
  echo "LEFT=$(ls -A "${GATE_TMP}" | wc -l | tr -d ' ')"
}
PASS_HEAD="$(gate_repo_commit 'echo "commit ${TEST_RUNNER_OVERTURE_GATE_COMMIT}"; echo "engine-divergence-gate: PASSED matches 6, records 0"')"
OUT="$(gate_run_out "${PASS_HEAD}")"
assert_contains "the gate's run reports its verdict" "${OUT}" "engine-divergence-gate: PASSED"
assert_contains "and is handed the commit it runs at" "${OUT}" "commit ${PASS_HEAD}"
assert_contains "and exits 0 when the suite does" "${OUT}" "RC=0"
assert_contains "and leaves no worktree behind" "${OUT}" "WORKTREES=1"
assert_contains "and no temporary folder" "${OUT}" "LEFT=0"
FAIL_HEAD="$(gate_repo_commit 'echo "the merge gate REFUSED"; exit 3')"
OUT="$(gate_run_out "${FAIL_HEAD}")"
assert_contains "a failed suite's exit code comes back" "${OUT}" "RC=3"
assert_contains "and the worktree is still removed" "${OUT}" "WORKTREES=1"
assert_contains "and the temporary folder" "${OUT}" "LEFT=0"
KILL_HEAD="$(gate_repo_commit 'kill -TERM "${PPID}"; sleep 5')"
OUT="$(gate_run_out "${KILL_HEAD}")"
assert_contains "an interrupted run says so in its exit code" "${OUT}" "RC=130"
assert_contains "and still removes its worktree" "${OUT}" "WORKTREES=1"
assert_contains "and its temporary folder" "${OUT}" "LEFT=0"
rm -rf "${GATE_REPO}" "${GATE_TMP}"

OUT="$(gate_files_out "scripts/lib/scratch.sh" "${GATE_SHA}" gate_fails)"
assert_contains "a PR touching no engine file is allowed" "${OUT}" "RC=0"
assert_contains "and says why the gate was not run" "${OUT}" "touches no queue engine file"
assert_contains "and runs nothing" "${OUT}" "RUNS=0"

OUT="$(gate_files_out "mac/Overture/App/QueueEngine.swift" "${GATE_SHA}" gate_passes)"
assert_contains "an engine PR whose suite says PASSED is allowed" "${OUT}" "RC=0"
assert_contains "and the suite ran once" "${OUT}" "RUNS=1"
assert_contains "and the verdict is printed" "${OUT}" "engine-divergence-gate: PASSED"

OUT="$(gate_files_out "mac/Overture/UI/QueueView.swift" "${GATE_SHA}" gate_fails)"
assert_contains "an engine PR whose suite failed is refused" "${OUT}" "RC=1"
assert_contains "and the refusal names the gate" "${OUT}" "queue engine's merge gate failed"

OUT="$(gate_files_out "mac/Overture/Domain/FactStore.swift" "${GATE_SHA}" gate_skipped)"
assert_contains "a run that never said PASSED (skipped, no live store) is refused" "${OUT}" "RC=1"
assert_contains "and says it was skipped or ran nothing" "${OUT}" "skipped or ran nothing"

OUT="$(gate_files_out "" "${GATE_SHA}" gate_passes)"
assert_contains "unreadable files refuse rather than reading as no engine change" "${OUT}" "RC=1"
assert_contains "and runs nothing" "${OUT}" "RUNS=0"

OUT="$(gate_files_out "mac/Overture/App/QueueEngine.swift" "abc1234" gate_passes)"
assert_contains "an abbreviated head is refused, since the stamp needs a whole commit" "${OUT}" "RC=1"

OUT="$(ALLOW_ENGINE_GATE_SKIP=1 gate_files_out "mac/Overture/App/QueueEngine.swift" "${GATE_SHA}" gate_fails)"
assert_contains "the override lets it through" "${OUT}" "RC=0"
assert_contains "and says out loud that it did" "${OUT}" "NOT checked by the queue engine's merge gate"
rm -f "${GATE_RUNS}"


# --- there is ONE implementation of the merge ---------------------------------------------------------
#
# The reason the fix above was needed twice: verify-and-merge-branch.sh and merge-when-green.sh each
# carried their own copy of the merge and the three steps that follow it, so the same defect had to be
# found and fixed in both. This asserts the copies have not come back, by name rather than by hope, and
# it is the guard that would go red if a third merge path were added with its own inline `gh pr merge`.
#
# Comments are stripped before matching, deliberately: every one of these files EXPLAINS the history in a
# comment, and a guard satisfied or broken by prose about the thing is indistinguishable from one that
# works (L103).
merge_call_sites() {
  local f base
  for f in "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/scripts/lib/*.sh; do
    base="$(basename "${f}")"
    [[ "${base}" == "pr-merge.sh" ]] && continue
    [[ "${base}" == *.test.sh ]] && continue
    if grep -qE 'pr[[:space:]]+merge' <<< "$(grep -v '^[[:space:]]*#' "${f}")"; then
      echo "${base}"
    fi
  done
}
CALLERS="$(merge_call_sites)"
assert_empty "no script but lib/pr-merge.sh invokes gh pr merge itself" "${CALLERS}"

# And the two callers really do reach the shared one, which is the other half of the same claim: a file
# that neither calls gh nor calls merge_pr would pass the check above while merging nothing.
for caller in verify-and-merge-branch.sh merge-when-green.sh; do
  if grep -q 'merge_pr' <<< "$(grep -v '^[[:space:]]*#' "${REPO_ROOT}/scripts/${caller}")"; then
    pass "${caller} merges through the shared merge_pr"
  else
    fail "${caller} does not call merge_pr, so it either cannot merge or has its own copy again"
  fi
done

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "pr-merge.test.sh: all assertions passed"
  exit 0
else
  echo "pr-merge.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
