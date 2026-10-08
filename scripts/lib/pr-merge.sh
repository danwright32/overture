#!/usr/bin/env bash

# The ONE implementation of "merge this PR and only then do the things that follow a merge", shared by
# every merge path in this repo: verify-and-merge-branch.sh, verify-and-merge-batch.sh and
# merge-when-green.sh.
#
# WHY IT IS SHARED. The sequence has four steps that must happen in order and must not happen at all if
# the merge did not: delete the local branch (#2234), record the shipped commit (#1808), report the
# installed build's freshness (#1345). Two scripts each carried their own copy of it, which is the
# two-near-copies-drifting shape #1073 and #982 are about, and the fix below was needed in both.
#
# WHY IT VERIFIES. Measured 2026-08-13, the first real run of verify-and-merge-batch.sh:
# `gh pr merge 2609` exited 1 with `GraphQL: Something went wrong while executing your query` (a transient
# GitHub fault, reproduced by hand a minute later), and the run printed `merged   PR #2609`, deleted the
# local branch of a PR that was still open, and exited 0. Two separate reasons it read as success:
#
#  1. Nothing looked at the merge command's status. The three steps after it ran unconditionally, and the
#     last two end in `|| true`, so the function's status was whatever `|| true` produced. Errexit could
#     not save it either, because callers invoke it from a place where errexit is suspended (an `if`
#     condition, an `||` list).
#  2. Even a zero status from the merge command is only a claim that the command worked. The claim a
#     caller acts on is that the PR reached MERGED, and only GitHub can answer that (L12: report what
#     verifiably happened).
#
# Nothing destructive happens until that answer is in, because deleting the local branch of an unmerged
# PR destroys good state before its replacement exists (L5). In the measured case the work survived only
# because the branch was already on origin.
#
# REQUIRES from the sourcing script: gh_as_danwright32 and REPO (scripts/ci-config.sh),
# delete_merged_local_branch (scripts/lib/checkout-tidy.sh), record_pr_decision
# (scripts/lib/pr-body-claims.sh), and REPO_ROOT.

# lessons_review_allows <pr-number>
#
# claude-config#560: no pull request merges until the lessons review of its whole branch has finished
# and its findings have reached the session. The session's merge gate (pr-review-gate.sh) sees only a
# command TYPED as a merge, and verify-and-merge-branch.sh and -batch.sh reach the merge through this
# file, so the verdict is asked here, where every route passes, from the same checker the gate uses:
# ~/.claude/hooks/lib/pr-review.sh check (PR_REVIEW_CHECK replaces it, for the tests). It is asked about
# the PULL REQUEST's head from GitHub, never the local HEAD, which can be a different commit.
#
# Refuses when the checker is missing or the head cannot be read, since merging something no review has
# read is what this exists to stop. SKIP_PR_REVIEW=1 in the environment skips it for one run, loudly;
# explain to Dan before using it.
lessons_review_allows() {
  local pr_number="$1" checker="${PR_REVIEW_CHECK:-${HOME}/.claude/hooks/lib/pr-review.sh}" head_base head base
  # The commit the review answered for, which merge_pr pins the merge to (L179). Empty when skipped.
  REVIEWED_HEAD=""
  if [[ "${SKIP_PR_REVIEW:-}" == "1" ]]; then
    echo "SKIP_PR_REVIEW=1: PR #${pr_number} was NOT held for the lessons review. Tell Dan why it was skipped." >&2
    return 0
  fi
  if [[ ! -f "${checker}" ]]; then
    echo "Refusing to merge PR #${pr_number}: the lessons review checker ${checker} is missing, so nothing has read this branch" >&2
    echo "against the recorded lessons. Install the shared config, or override for one run, explained to Dan first: SKIP_PR_REVIEW=1." >&2
    return 1
  fi
  head_base="$(gh_as_danwright32 pr view "${pr_number}" -R "${REPO}" --json headRefOid,baseRefName --jq '.headRefOid + "\t" + .baseRefName' 2>/dev/null || echo "")"
  head="${head_base%%$'\t'*}"
  base="${head_base#*$'\t'}"
  if [[ -z "${head}" ]]; then
    echo "Refusing to merge PR #${pr_number}: could not read its head from GitHub, so no lessons review can answer for it." >&2
    echo "Override for one run, explained to Dan first: SKIP_PR_REVIEW=1." >&2
    return 1
  fi
  local out rc=0
  out="$(bash "${checker}" check --dir "${REPO_ROOT}" --sha "${head}" --base-ref "origin/${base:-main}" 2>&1)" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    printf '%s\n' "${out}" >&2
    return 1
  fi
  printf '%s\n' "${out}"
  REVIEWED_HEAD="${head}"
  return 0
}

# #4358 slice E4d (plan v7 section 15, the E4 plan's section 4): THE QUEUE ENGINE'S MERGE GATE.
#
# A pull request that touches the queue engine merges only when the BRANCH'S OWN verifier, over a clone of Dan's live
# store, matched a fresh read at least five times and recorded nothing (`EngineDivergenceGateTests`, which holds the
# rule). GitHub's runners have no live store, so this Mac is the only place it can run, and the merge path is where
# every merge passes (L593). It runs the suite at the PR head, in a throwaway worktree, with the head's commit in
# TEST_RUNNER_OVERTURE_GATE_COMMIT so the run's log lines are stamped as that commit's test run.
#
# Refuses, by name: files it cannot read (an empty list is what a failed gh call returns, L98), a run that failed, and
# a run that did not print the suite's PASSED line, which is what a skipped or crashed suite looks like. Allows, and
# says so, a PR that touches no engine file. ALLOW_ENGINE_GATE_SKIP=1 skips it for one command, loudly; explain to Dan
# first. ENGINE_GATE_RUNNER replaces the run, for the fixture.
ENGINE_GATE_PATHS_RE='^mac/Overture/(App/QueueEngine|App/RootView\.swift|Domain/QueueEngine|Domain/FactStore\.swift|Domain/ShowIdentity\.swift|Domain/CardDivergence|UI/QueueRenderPass\.swift|UI/QueueView)'
ENGINE_GATE_PASSED_LINE='engine-divergence-gate: PASSED'

# engine_gate_run <head-sha>: the suite at that commit, in a worktree of its own, removed afterwards on EVERY exit,
# an interrupt included, by a trap in a subshell of its own (L114, L473; the lessons review of E4d1). No deadline of
# its own: run-tests-locked.sh ends a run that stops moving and says STALLED AND ENDED (#3976), which this then
# reports as a failed gate.
engine_gate_run() {
  local head="$1" parent
  parent="$(mktemp -d "${TMPDIR:-/tmp}/overture-engine-gate.XXXXXX")" || return 1
  (
    # Copied out of the function's scope (its locals, and a REPO_ROOT given for the call alone), which an EXIT trap
    # reached from a signal trap no longer sees under macOS bash 3.2 (measured: `parent: unbound variable` under
    # set -u, and the worktree left behind in the repository the call named).
    gate_parent="${parent}"
    gate_repo="${REPO_ROOT}"
    wt="${gate_parent}/tree"
    engine_gate_cleanup() {
      git -C "${gate_repo}" worktree remove --force "${wt}" >/dev/null 2>&1 || true
      rm -rf "${gate_parent}"
      git -C "${gate_repo}" worktree prune >/dev/null 2>&1 || true
    }
    trap engine_gate_cleanup EXIT
    trap 'exit 130' INT TERM
    git -C "${gate_repo}" worktree add --detach --quiet "${wt}" "${head}" 2>&1 || exit 1
    TEST_RUNNER_OVERTURE_GATE_COMMIT="${head}" \
      "${wt}/mac/scripts/run-tests-locked.sh" -only-testing:OvertureTests/EngineDivergenceGateTests 2>&1
  )
}

# engine_gate_allows <pr-number> <head-sha>
engine_gate_allows() {
  local pr_number="$1" head="$2" files out rc=0
  if [[ "${ALLOW_ENGINE_GATE_SKIP:-}" == "1" ]]; then
    echo "ALLOW_ENGINE_GATE_SKIP=1: PR #${pr_number} was NOT checked by the queue engine's merge gate. Tell Dan why it was skipped." >&2
    return 0
  fi
  files="$(gh_as_danwright32 pr view "${pr_number}" -R "${REPO}" --json files --jq '.files[].path' 2>/dev/null)" || files=""
  if [[ -z "${files}" ]]; then
    echo "Refusing to merge PR #${pr_number}: its changed files could not be read, so whether it touches the queue engine is unknown." >&2
    return 1
  fi
  if ! grep -Eq "${ENGINE_GATE_PATHS_RE}" <<< "${files}"; then
    echo "engine gate: PR #${pr_number} touches no queue engine file, so the live clone gate was not needed."
    return 0
  fi
  if [[ ! "${head}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Refusing to merge PR #${pr_number}: the queue engine's merge gate needs the head's whole commit, and got '${head}'." >&2
    return 1
  fi
  echo "engine gate: PR #${pr_number} touches the queue engine; running its verifier over the live clone at ${head}."
  out="$("${ENGINE_GATE_RUNNER:-engine_gate_run}" "${head}")" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    printf '%s\n' "${out}" | tail -40 >&2
    echo "Refusing to merge PR #${pr_number}: the queue engine's merge gate failed (exit ${rc}); its output is above." >&2
    return 1
  fi
  if ! grep -Fq "${ENGINE_GATE_PASSED_LINE}" <<< "${out}"; then
    printf '%s\n' "${out}" | tail -40 >&2
    echo "Refusing to merge PR #${pr_number}: the gate suite did not say PASSED, so it was skipped or ran nothing (no live store, or no run)." >&2
    return 1
  fi
  grep -F "${ENGINE_GATE_PASSED_LINE}" <<< "${out}"
  return 0
}

# merge_pr <pr-number> [local-branch-name]
#
# Returns 0 only when GitHub confirms the PR is MERGED. Prints the reason and returns 1 otherwise,
# having changed nothing else.
merge_pr() {
  local pr_number="$1" merged_branch="${2:-}"

  if ! lessons_review_allows "${pr_number}"; then
    echo "PR #${pr_number} was not merged: the lessons review has not cleared it (above). Nothing else was done to it." >&2
    return 1
  fi

  # #4358 slice E4d: the queue engine's merge gate, at the commit the review read (or the PR's head when the review
  # was skipped), before GitHub is asked for anything.
  local gate_head="${REVIEWED_HEAD:-}"
  if [[ -z "${gate_head}" ]]; then
    gate_head="$(gh_as_danwright32 pr view "${pr_number}" -R "${REPO}" --json headRefOid --jq .headRefOid 2>/dev/null || echo "")"
  fi
  if ! engine_gate_allows "${pr_number}" "${gate_head}"; then
    echo "PR #${pr_number} was not merged: the queue engine's merge gate refused it (above). Nothing else was done to it." >&2
    return 1
  fi

  # Pinned to the commit the review read, so a push landing between the check and this line is
  # refused by GitHub rather than merged unreviewed (L179; the first real review of this change
  # found the gap).
  # Expanded with the guarded form below: macOS bash 3.2 under set -u errors on an EMPTY array (L486).
  # #4358 slice E4d: with the review skipped there is no REVIEWED_HEAD, so the merge is pinned to the head the engine
  # gate ran at instead, and a push between that run and this line is refused rather than merged unseen (L179).
  local pin=() merge_head="${REVIEWED_HEAD:-}"
  [[ -z "${merge_head}" && "${gate_head}" =~ ^[0-9a-f]{40}$ ]] && merge_head="${gate_head}"
  [[ -n "${merge_head}" ]] && pin=(--match-head-commit "${merge_head}")
  if ! gh_as_danwright32 pr merge "${pr_number}" -R "${REPO}" --squash --delete-branch ${pin[@]+"${pin[@]}"}; then
    echo "gh refused to merge PR #${pr_number}; its message is above. Nothing else was done to it," >&2
    echo "so the branch is untouched and this can be rerun once the cause is dealt with." >&2
    return 1
  fi

  local state
  state="$(gh_as_danwright32 pr view "${pr_number}" -R "${REPO}" --json state --jq .state 2>/dev/null || echo "")"
  if [[ "${state}" != "MERGED" ]]; then
    echo "gh reported success, but PR #${pr_number} reads as ${state:-unreadable} rather than MERGED." >&2
    echo "Treating it as NOT merged: nothing was deleted and no shipped commit was recorded." >&2
    return 1
  fi

  # #2234: --delete-branch only removes the branch on GitHub. Without this the local ref survives
  # every merge, which is how the checkout reached 496 branches. Never fatal: the merge is confirmed,
  # and failing here would report a landed change as a failure.
  delete_merged_local_branch "${merged_branch}" || true
  # #1808: something shipped, so record it for the app to compare its own build against, and say the
  # same thing in the terminal (which is what finally gives #1345's freshness check a caller). Neither
  # is fatal, for the same reason.
  "${REPO_ROOT}/scripts/record-shipped-commit.sh" || true
  "${REPO_ROOT}/mac/scripts/check-release-freshness.sh" || true
  # #3187: a decision this body quotes that no comment on its issues carries lives only here, in a merged
  # PR body, which is not somewhere anybody looks. Written to the issue now, after the merge is
  # confirmed and never before, because a call recorded for a PR that did not land is a decision nobody
  # made sitting where one somebody made would sit. Here rather than in either caller so all three merge
  # paths get it from one place, and never fatal for the same reason as the two lines above.
  PR_BODY_CLAIMS_GH=gh_as_danwright32 record_pr_decision "${pr_number}" || true
  # Explicit, so neither of those `|| true` lines can be mistaken for this function's verdict again.
  return 0
}
