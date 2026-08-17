#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/shell-assertions.sh"

# #2234: the decisions tidy-checkout.sh makes about what may be deleted, exercised as pure
# functions with no git, no gh, and no filesystem.
#
# The whole point of the issue is that the OBVIOUS containment test is wrong here. This repo
# squash-merges, so a fully shipped branch is never an ancestor of main and `git branch --merged`
# recognises almost none of them. Every test below is really asking one question: can this logic
# ever delete a branch whose work has not shipped? So the cases that matter most are the ones that
# assert something is KEPT.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./checkout-tidy.sh
source "${SCRIPT_DIR}/checkout-tidy.sh"
set +e

FAILURES=0

assert_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_status() {
  local desc="$1" expected="$2"
  shift 2
  "$@" >/dev/null 2>&1
  local actual=$?
  if [[ "${actual}" -eq "${expected}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected exit: ${expected}"
    echo "  actual exit:   ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

# ---------------------------------------------------------------------------
# cherry_says_contained: reading `git cherry main <branch>` output
# ---------------------------------------------------------------------------
# `git cherry` prefixes a commit whose patch is ALREADY present in main with "-", and one that is
# missing with "+". Empty output means the branch has nothing main does not already have.

assert_status "no output at all means every commit is already in main" 0 \
  cherry_says_contained ""

assert_status "every commit marked '-' means every patch landed" 0 \
  cherry_says_contained "- 1111111111111111111111111111111111111111
- 2222222222222222222222222222222222222222"

assert_status "a single '+' commit means work that has not shipped" 1 \
  cherry_says_contained "+ 1111111111111111111111111111111111111111"

# The dangerous case: most commits landed, one did not. Deleting here loses that one.
assert_status "one '+' among several '-' still counts as unshipped" 1 \
  cherry_says_contained "- 1111111111111111111111111111111111111111
+ 2222222222222222222222222222222222222222
- 3333333333333333333333333333333333333333"

# git cherry writes nothing but these two prefixes, so anything else is a shape it does not
# understand, and an unrecognised line must never be read as proof of containment.
assert_status "an unrecognised line is not proof of anything" 1 \
  cherry_says_contained "fatal: unknown revision or path not in the working tree."

# ---------------------------------------------------------------------------
# classify_branch: the verdict for one local branch
# ---------------------------------------------------------------------------
# Arguments: branch, current_branch, cherry_output, merged_pr_count, open_pr_count, worktree_branches

assert_eq "main is protected no matter what anything else says" \
  "$(classify_branch "main" "some-branch" "" "1" "0" "")" \
  "protected"

assert_eq "the branch you are standing on is protected" \
  "$(classify_branch "my-work" "my-work" "" "1" "0" "")" \
  "protected"

# A branch whose patches are all in main but whose PR is still open is work in progress against a
# base that already moved. Deleting it would take the branch out from under a live PR.
assert_eq "an open PR keeps the branch even when every patch is already in main" \
  "$(classify_branch "feature-x" "main" "- 1111111111111111111111111111111111111111" "0" "1" "")" \
  "open-pr"

assert_eq "a branch checked out in a worktree is never deleted" \
  "$(classify_branch "feature-x" "main" "" "1" "0" "feature-x
other-branch")" \
  "in-worktree"

# The case `git branch --merged` gets wrong. A squashed merge combines several commits into one, so
# no individual commit's patch-id matches and cherry reports "+" for all of them. The merged PR is
# what proves it shipped.
assert_eq "a merged PR proves a squashed branch shipped even when cherry disagrees" \
  "$(classify_branch "feature-x" "main" "+ 1111111111111111111111111111111111111111
+ 2222222222222222222222222222222222222222" "1" "0" "")" \
  "shipped"

assert_eq "cherry containment alone is enough when there is no PR record" \
  "$(classify_branch "feature-x" "main" "- 1111111111111111111111111111111111111111" "0" "0" "")" \
  "shipped"

assert_eq "no merged PR and commits missing from main means keep it" \
  "$(classify_branch "feature-x" "main" "+ 1111111111111111111111111111111111111111" "0" "0" "")" \
  "unshipped"

# gh being unavailable or unauthenticated yields an empty count, not a zero. It must not read as
# "no merged PR exists", and it must never be the thing that unlocks a delete on its own.
assert_eq "an unreadable PR count falls back to cherry and keeps the branch" \
  "$(classify_branch "feature-x" "main" "+ 1111111111111111111111111111111111111111" "" "" "")" \
  "unshipped"

assert_eq "an unreadable PR count still allows a delete when cherry proves containment" \
  "$(classify_branch "feature-x" "main" "" "" "" "")" \
  "shipped"

# ---------------------------------------------------------------------------
# classify_branch_before_cherry: the cheap pass, which is what the driver actually calls
# ---------------------------------------------------------------------------
# `git cherry` costs a patch-id per commit per branch, and there are hundreds of branches, so the
# driver only pays for it when nothing cheaper settled the question. That makes this function the
# one that runs in anger, and a precedence bug here would not be caught by classify_branch's tests
# alone. Every case below is the same input as its classify_branch twin, asserting the two agree.

assert_eq "the cheap pass protects main without consulting anything" \
  "$(classify_branch_before_cherry "main" "some-branch" "1" "0" "")" \
  "protected"

assert_eq "the cheap pass protects the current branch" \
  "$(classify_branch_before_cherry "my-work" "my-work" "1" "0" "")" \
  "protected"

assert_eq "the cheap pass keeps a branch with an open PR" \
  "$(classify_branch_before_cherry "feature-x" "main" "0" "1" "")" \
  "open-pr"

assert_eq "the cheap pass keeps a branch a worktree has checked out" \
  "$(classify_branch_before_cherry "feature-x" "main" "1" "0" "feature-x")" \
  "in-worktree"

assert_eq "a merged PR settles it with no cherry needed" \
  "$(classify_branch_before_cherry "feature-x" "main" "1" "0" "")" \
  "shipped"

# The one answer that costs money. Anything reaching here has no PR record either way, which is the
# minority case, and is why the expensive call is worth avoiding for the rest.
assert_eq "no PR evidence at all is the only case that pays for cherry" \
  "$(classify_branch_before_cherry "feature-x" "main" "0" "0" "")" \
  "needs-cherry"

assert_eq "an unreadable PR count also falls through to cherry" \
  "$(classify_branch_before_cherry "feature-x" "main" "" "" "")" \
  "needs-cherry"

# ---------------------------------------------------------------------------
# classify_worktree: the verdict for one registered worktree
# ---------------------------------------------------------------------------
# Arguments: path_exists, is_main, dirty, contained

assert_eq "the repo's own worktree is never touched" \
  "$(classify_worktree "yes" "yes" "no" "yes")" \
  "keep-main"

assert_eq "a registration whose directory is gone is prunable" \
  "$(classify_worktree "no" "no" "no" "no")" \
  "prunable"

assert_eq "uncommitted work in a worktree keeps it, shipped branch or not" \
  "$(classify_worktree "yes" "no" "yes" "yes")" \
  "keep-dirty"

assert_eq "a clean worktree on an unshipped branch is kept" \
  "$(classify_worktree "yes" "no" "no" "no")" \
  "keep-unshipped"

assert_eq "a clean worktree whose work has shipped can go" \
  "$(classify_worktree "yes" "no" "no" "yes")" \
  "removable"

# ---------------------------------------------------------------------------
# local_branch_deletable: the post-merge cleanup the merge scripts call
# ---------------------------------------------------------------------------
# The merge already happened, so containment is not in question here. The only remaining question
# is whether deleting the local ref would pull it out from under something.

assert_eq "the just-merged branch is deleted once its PR is in" \
  "$(local_branch_deletable "feature-x" "main" "")" \
  "deletable"

assert_eq "refusing to delete main even if something asks" \
  "$(local_branch_deletable "main" "main" "")" \
  "protected"

assert_eq "not deleting the branch the merge was run from" \
  "$(local_branch_deletable "feature-x" "feature-x" "")" \
  "protected"

assert_eq "not deleting a branch another worktree still has checked out" \
  "$(local_branch_deletable "feature-x" "main" "feature-x")" \
  "in-worktree"

# An empty branch name means the caller could not work out what was merged. Doing nothing is the
# only safe reading; a `git branch -D ""` would be an error at best.
assert_eq "an unknown branch name is never acted on" \
  "$(local_branch_deletable "" "main" "")" \
  "protected"

echo
# ---------------------------------------------------------------------------
# branch_backlog_report: say when the backlog is climbing again (#2302)
# ---------------------------------------------------------------------------
# #2234 fixed the two leaks it could reach (both merge scripts now delete the local branch they just
# landed, and this script clears a backlog). Neither covers the paths that are not a merge script: a
# branch made by hand and abandoned, an agent worktree, or the bare one-line merge the next-issue
# shortcut uses. So the count can still climb with nobody watching, which is exactly how it reached
# 496 the first time: not because anyone chose to keep them, but because nothing ever counted them.
#
# The obvious check agrees that all is well the whole way up, since this repo squash-merges and
# `git branch --merged main -d` recognised 39 of those 496.

assert_eq "an ordinary checkout is not worth a word" \
  "$(branch_backlog_report 27 50)" \
  ""

# The boundary is stated rather than left to be inferred. At the threshold exactly, nothing is said:
# the line exists to report a count that has gone PAST the point where somebody should look.
assert_eq "a count exactly at the threshold is still not worth a word" \
  "$(branch_backlog_report 50 50)" \
  ""

BACKLOG_LINE="$(branch_backlog_report 512 50)"

assert_eq "a backlog past the threshold states the count it measured" \
  "$(printf '%s' "${BACKLOG_LINE}" | grep -c '512 local branches')" \
  "1"

# What it MEASURED is refs. It must not claim they are dead ones: this counts nothing about whether
# a branch has shipped, and the whole reason #2234 exists is that the cheap answer to that question
# is wrong here (L11: a message may claim only what its check actually measured).
assert_eq "it never claims to have measured which of them are dead" \
  "$(printf '%s' "${BACKLOG_LINE}" | grep -ci 'dead branches\|shipped branches')" \
  "0"

# And it names the command that decides, or the count is a number with nowhere to go (L80).
assert_eq "it names the command that answers which of them can go" \
  "$(printf '%s' "${BACKLOG_LINE}" | grep -c 'scripts/tidy-checkout.sh')" \
  "1"

assert_eq "and says it is advisory, since a cluttered checkout is nobody's defect" \
  "$(printf '%s' "${BACKLOG_LINE}" | grep -ci 'advisory')" \
  "1"

# A count that is not a number is not a small count. It must never reach the comparison and land on
# the quiet side, which is the one direction this can fail in (L50).
assert_eq "an unreadable count says nothing rather than reading as healthy" \
  "$(branch_backlog_report "" 50)" \
  ""

assert_eq "and neither does an unreadable threshold turn every checkout into a backlog" \
  "$(branch_backlog_report 512 "")" \
  ""

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All checkout-tidy.sh fixtures passed."
  exit 0
fi
echo "${FAILURES} checkout-tidy.sh fixture(s) failed." >&2
exit 1
