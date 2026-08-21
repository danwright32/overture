#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=./shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shell-assertions.sh"

# #2946: coverage for scripts/lib/copy-docs-rebuild.sh.
#
# The real thing runs the Swift suite, which no fixture may do, so the generators are stubbed: the
# worktree gets a fake `mac/scripts/run-tests-locked.sh` that writes whatever this fixture tells it to.
# What is under test is the DECISION around that run, which is the whole of the risk: what gets
# committed, what is refused, and what is said.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./copy-docs-rebuild.sh
source "${HERE}/copy-docs-rebuild.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# A worktree with the three documents committed and a stub runner in the place the real one lives.
make_worktree() {
  local dir="${WORK}/wt-$1"; shift
  local runner_body="$1"
  rm -rf "${dir}"
  mkdir -p "${dir}/docs" "${dir}/mac/scripts"
  git -C "${dir}" init -q
  git -C "${dir}" config user.email t@localhost
  git -C "${dir}" config user.name t
  for f in "${COPY_DOC_PATHS[@]}"; do printf 'before\n' > "${dir}/${f}"; done
  printf 'source\n' > "${dir}/mac/source.swift"
  { echo '#!/usr/bin/env bash'; echo "cd \"\$(dirname \"\$0\")/../..\""; echo "${runner_body}"; } \
    > "${dir}/mac/scripts/run-tests-locked.sh"
  chmod +x "${dir}/mac/scripts/run-tests-locked.sh"
  # Committed BEFORE the rebuild runs, because the real worktree's runner is tracked too. Leaving it
  # untracked would have the fixture testing a state the real thing is never in.
  git -C "${dir}" add -A
  git -C "${dir}" commit -q -m base
  echo "${dir}"
}

# --- the ordinary case: another branch moved the documents, so they are rebuilt and committed ---------
DIR="$(make_worktree rebuilt 'printf "after\n" > docs/copy-inventory.md; exit 1')"
OUT="$(rebuild_copy_docs "${DIR}" 2>&1)"
STATUS=$?
assert_equals "a rebuild that moved a document succeeds" "0" "${STATUS}"
assert_contains "and says it rebuilt them" "${OUT}" "Rebuilt the copy documents"
assert_empty "and leaves the worktree clean" "$(git -C "${DIR}" status --porcelain)"
assert_equals "and the rebuilt text is committed" "after" "$(git -C "${DIR}" show HEAD:docs/copy-inventory.md)"

# The scoped run FAILS by design when it regenerates (#1994), so the run's own exit status must never be
# the verdict. The stub above exits 1 and the rebuild still has to land: if this ever starts reading the
# status, that assertion is the one that goes red.
assert_contains "a failing generator run is still read by what it WROTE" "${OUT}" "Rebuilt"

# --- nothing moved: say so, commit nothing -----------------------------------------------------------
DIR="$(make_worktree unchanged 'exit 0')"
BEFORE="$(git -C "${DIR}" rev-parse HEAD)"
OUT="$(rebuild_copy_docs "${DIR}" 2>&1)"
STATUS=$?
assert_equals "a tree already in step succeeds" "0" "${STATUS}"
assert_contains "and says nothing was rebuilt" "${OUT}" "nothing rebuilt"
assert_equals "and records no commit" "${BEFORE}" "$(git -C "${DIR}" rev-parse HEAD)"

# --- the refusal: something OTHER than the generators wrote to the worktree ---------------------------
# A blind commit here would record a change nobody asked for while looking exactly like a correct one,
# which is commit_merge_regeneration's rule and the reason this is not just `git add -A`.
DIR="$(make_worktree strayed 'printf "after\n" > docs/copy-inventory.md; printf "tampered\n" > mac/source.swift; exit 1')"
OUT="$(rebuild_copy_docs "${DIR}" 2>&1)"
STATUS=$?
assert_equals "a run that touched anything else is refused" "1" "${STATUS}"
assert_contains "and names the file it does not own" "${OUT}" "mac/source.swift"
assert_contains "and says nothing was merged" "${OUT}" "Nothing was merged"
assert_equals "and commits nothing" "1" "$(git -C "${DIR}" rev-list --count HEAD)"

# --- all three documents are covered, not just the inventory -----------------------------------------
# The issue names the inventory; there are three generated copy documents and they go stale together.
DIR="$(make_worktree allthree 'printf "after\n" > docs/copy-inventory.md; printf "after\n" > docs/outbound-copy.md; printf "after\n" > docs/copy-surfaces.md; exit 1')"
rebuild_copy_docs "${DIR}" > /dev/null 2>&1
for f in docs/copy-inventory.md docs/outbound-copy.md docs/copy-surfaces.md; do
  assert_equals "${f} is committed by the rebuild" "after" "$(git -C "${DIR}" show "HEAD:${f}")"
done

# --- the two merge paths both call it, and both call it BEFORE the suite ------------------------------
# Asserted on the source, because a fixture cannot see the ordering from outside, and running it after
# the suite would settle the documents for a run that had already judged them (L100's shape).
for script in "${HERE}/../verify-and-merge-branch.sh" "${HERE}/../verify-and-merge-batch.sh"; do
  SRC="$(cat "${script}")"
  name="$(basename "${script}")"
  assert_contains "${name} rebuilds the copy documents" "${SRC}" "rebuild_copy_docs"
  REBUILD_LINE="$(grep -n 'rebuild_copy_docs "\${WORKTREE_DIR}"' "${script}" | head -1 | cut -d: -f1)"
  SUITE_LINE="$(grep -n 'run_full_suite "\${WORKTREE_DIR}"' "${script}" | head -1 | cut -d: -f1)"
  assert_equals "${name} rebuilds BEFORE it runs the suite" "1" \
    "$([ -n "${REBUILD_LINE}" ] && [ -n "${SUITE_LINE}" ] && [ "${REBUILD_LINE}" -lt "${SUITE_LINE}" ] && echo 1 || echo 0)"
done

# --- an UNTRACKED stray is not a refusal --------------------------------------------------------------
# Only the three paths are ever staged, so a stray cannot reach the commit whatever this says. Refusing
# over one would block a merge because a test run dropped a log in the tree, which is a gate that fires
# on the ordinary case (L93). A tracked file that MOVED is still refused, which the case above proves.
DIR="$(make_worktree stray 'printf "after\n" > docs/copy-inventory.md; printf "log\n" > mac/scratch.log; exit 1')"
OUT="$(rebuild_copy_docs "${DIR}" 2>&1)"
STATUS=$?
assert_equals "an untracked stray does not refuse the rebuild" "0" "${STATUS}"
assert_equals "and the rebuild is still committed" "after" "$(git -C "${DIR}" show HEAD:docs/copy-inventory.md)"
assert_empty "and the stray is not committed" "$(git -C "${DIR}" ls-files mac/scratch.log)"

if [[ "${FAILURES:-0}" -ne 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all copy-docs-rebuild.sh checks passed"
