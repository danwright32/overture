#!/usr/bin/env bash
set -uo pipefail

# Coverage for the shared "is this directory mine to scrub" guard (#2923).
#
# The instance that caused the issue was mac/scripts/lib/update-sync.sh moving a working checkout off an
# in-progress branch. The CLASS is every place a merge path points a force-detach, a `git clean -ffdx`,
# a `worktree remove --force` or an `rm -rf` at a directory it believes is a throwaway. There are two
# such places, both derived from `grep -rn 'checkout' scripts/*.sh scripts/lib/*.sh`:
#
#   scripts/verify-and-merge-branch.sh   setup_worktree, over ${OVERTURE_VERIFY_WORKTREE}
#   scripts/lib/project-freshness.sh     gate_branch_project_freshness, over the dir its caller hands it
#
# Neither aims at the working checkout today. Both take the directory from a caller or an environment
# variable, and both would do their whole job to it without hesitating: force-detach it onto another
# ref, clean every untracked file out of it, and in the first case delete the directory outright. The
# damage from #2923 was one branch switch nobody could see; the damage available here is the same switch
# plus the tree.
#
# What tells them apart is evidence rather than a name: the verify slot is created with
# `worktree add --detach` and is detached for the whole of its life, so a directory standing on a NAMED
# branch is somebody's working checkout, whatever it is called or wherever it was pointed.

# shellcheck source=./shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shell-assertions.sh"

FAILURES=0
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${LIB_DIR}/.." && pwd)"

# shellcheck source=./worktree-safety.sh
source "${LIB_DIR}/worktree-safety.sh"

# --- the decision -------------------------------------------------------------------------
# scratch_worktree_verdict PATH_EXISTS IS_WORKING_CHECKOUT HEAD_BRANCH

assert_equals "a detached directory of this repo's own is scratch" \
  "scratch" "$(scratch_worktree_verdict yes no HEAD)"

assert_equals "a path that does not exist yet is scratch: there is nothing there to protect" \
  "scratch" "$(scratch_worktree_verdict no no "")"

assert_equals "a directory that is not a worktree at all is scratch" \
  "scratch" "$(scratch_worktree_verdict yes no "")"

# An unmade comparison is its own answer, never folded into either of the two it sits between: reported
# as the working checkout it would state as measured fact something nothing measured, and reported as
# scratch it would be the one unreadable answer that points at the destructive branch (L11, L42).
assert_equals "a comparison that could not be made is refused in its own words" \
  "refuse:cannot-tell" "$(scratch_worktree_verdict yes unknown HEAD)"

# THE ONE #2923 IS ABOUT. A named branch is a session standing in it.
assert_equals "a directory standing on a named branch is refused" \
  "refuse:on-a-branch" "$(scratch_worktree_verdict yes no fix-2893-form-or-dm-needs-a-route)"

# The working checkout is refused even while detached, which is the state a previous run of one of these
# very functions could have left it in. Two independent facts, so neither one alone decides (L70).
assert_equals "the working checkout is refused even detached" \
  "refuse:working-checkout" "$(scratch_worktree_verdict yes yes HEAD)"

# Order must not decide the safe answer: a working checkout that is also on a branch is still refused,
# and by the reason that names what it is rather than where it is standing.
assert_equals "the working checkout on main is refused as the working checkout" \
  "refuse:working-checkout" "$(scratch_worktree_verdict yes yes main)"

# --- the gathering, against real git ---------------------------------------------------------
#
# Real repositories rather than a stub, because the whole claim is about what git reports for a
# directory, and a stub could only confirm what this file already assumes (L52).

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/overture-worktree-safety-2923.XXXXXX")" && pwd -P)"
trap 'rm -rf "${WORK}"' EXIT

REPO="${WORK}/repo"
git init --quiet -b main "${REPO}"
git -C "${REPO}" config user.email t@example.com
git -C "${REPO}" config user.name Test
echo one > "${REPO}/file.txt"
git -C "${REPO}" add -A
git -C "${REPO}" commit --quiet -m first

SLOT="${WORK}/slot"
git -C "${REPO}" worktree add --quiet --detach "${SLOT}" HEAD 2>/dev/null

out="$(require_scratch_worktree "${SLOT}" "${REPO}" "the verify worktree" 2>&1)"
assert_equals "the detached slot is allowed through" "0" "$?"
assert_empty "and says nothing while doing so" "${out}"

out="$(require_scratch_worktree "${WORK}/never-created" "${REPO}" "the verify worktree" 2>&1)"
assert_equals "a slot that has not been created yet is allowed through" "0" "$?"

out="$(require_scratch_worktree "${REPO}" "${REPO}" "the verify worktree" 2>&1)"
status=$?
assert_equals "the working checkout itself is refused" "1" "${status}"
assert_contains "and the refusal names the directory" "${out}" "${REPO}"
assert_contains "and says what would have been done to it" "${out}" "the verify worktree"

# A repo root that is not there at all. The comparison cannot be made, so the answer is a refusal that
# says exactly that rather than one of the two neighbouring claims.
out="$(require_scratch_worktree "${SLOT}" "${WORK}/no-such-root" "the verify worktree" 2>&1)"
status=$?
assert_equals "an unmakeable comparison refuses" "1" "${status}"
assert_contains "and says the comparison is what failed" "${out}" "could not be compared"
assert_not_contains "rather than claiming it IS the working checkout" \
  "${out}" "it is the checkout this script is running from"

# A second checkout of the same repo, on a branch: not REPO_ROOT, so only the branch tells it apart.
SIDE="${WORK}/side"
git -C "${REPO}" worktree add --quiet -b fix-2893-form-or-dm-needs-a-route "${SIDE}" 2>/dev/null
out="$(require_scratch_worktree "${SIDE}" "${REPO}" "the verify worktree" 2>&1)"
status=$?
assert_equals "a checkout standing on a branch is refused even when it is not the main one" "1" "${status}"
assert_contains "and the refusal names the branch, so the person can tell whose work it is" \
  "${out}" "fix-2893-form-or-dm-needs-a-route"

# --- the wiring: both call sites actually ask ------------------------------------------------
#
# A shared guard nothing calls leaves both places exactly as they were. Each check is scoped to the
# FUNCTION that does the scrubbing, never to the whole file, so an unrelated later mention elsewhere in
# it cannot answer for the region this is about (L135).

sed -n '/^setup_worktree() {/,/^}/p' "${SCRIPTS_DIR}/verify-and-merge-branch.sh" > "${WORK}/setup_worktree.txt"
assert_contains "setup_worktree asks before it scrubs or deletes anything" \
  "$(cat "${WORK}/setup_worktree.txt")" "require_scratch_worktree"

sed -n '/^gate_branch_project_freshness() {/,/^}/p' "${LIB_DIR}/project-freshness.sh" \
  > "${WORK}/gate.txt"
assert_contains "gate_branch_project_freshness asks before it detaches anything" \
  "$(cat "${WORK}/gate.txt")" "require_scratch_worktree"

# And the guard has to run BEFORE the destructive part of setup_worktree, not beside it: the fallback
# path removes the worktree registration and then `rm -rf`s the directory.
#
# Comment lines are stripped before the two are located, because both this file's own explanation and
# setup_worktree's name the very commands being looked for, and a line ABOUT a thing would otherwise
# answer for the line that does it (L103).
setup_body="$(grep -v '^[[:space:]]*#' "${WORK}/setup_worktree.txt")"
guard_line="$(grep -n "require_scratch_worktree" <<< "${setup_body}" | head -1 | cut -d: -f1)"
rm_line="$(grep -n "^[[:space:]]*rm -rf" <<< "${setup_body}" | head -1 | cut -d: -f1)"
if [[ -n "${guard_line}" && -n "${rm_line}" && "${guard_line}" -lt "${rm_line}" ]]; then
  pass "and it asks before the rm -rf, not after it"
else
  fail "and it asks before the rm -rf, not after it" "guard=${guard_line} rm=${rm_line}"
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} check(s) failed"
  exit 1
fi
echo "all worktree-safety checks passed"
