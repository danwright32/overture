#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary (#2501).
# shellcheck source=./shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shell-assertions.sh"

# Coverage for trial_merge_conflicts (#3210): asking THIS repo's own merge machinery whether a
# collision GitHub reports as CONFLICTING is one a person has to resolve, or one the generated-file
# merge driver settles by itself.
#
# Driven against REAL throwaway git repositories with real commits, never a stub of git. The whole
# question is whether `git merge-tree` runs a custom merge driver, which is a fact about the
# installed git and this repo's config, and a stub could only ever confirm what was assumed (L52).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./generated-conflict.sh
source "${SCRIPT_DIR}/generated-conflict.sh"
set +e

FAILURES=0

WORK="$(mktemp -d "${TMPDIR:-/tmp}/generated-conflict-fixture.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

# A repository holding one generated file (the driver's own first path) and one ordinary file, with
# two branches that both change both. `install_driver` decides whether this clone has run
# scripts/install-git-hooks.sh, which is the difference the fixture exists to exercise.
make_repo() {
  local dir="$1" install_driver="$2"
  mkdir -p "${dir}/docs"
  git -C "${dir}" init -q -b main
  git -C "${dir}" config user.email "fixture@localhost"
  git -C "${dir}" config user.name "Fixture"
  printf 'docs/copy-inventory.md merge=overture-generated\n' > "${dir}/.gitattributes"
  printf 'base\n' > "${dir}/docs/copy-inventory.md"
  printf 'base\n' > "${dir}/docs/contracts.md"
  git -C "${dir}" add -A
  git -C "${dir}" commit -q -m base
  if [[ "${install_driver}" == "with-driver" ]]; then
    # The REAL driver, at the RELATIVE path the real config names. Both halves matter. A copy of the
    # script keeps this fixture asking what git does with the code that actually ships, rather than
    # with a stand-in; and git runs a driver through a shell from the repository root, so an absolute
    # path is enough on its own to make the driver silently never run here, this checkout's own path
    # holding spaces. That is how the first version of this fixture reported a conflict the real repo
    # resolves.
    mkdir -p "${dir}/scripts/lib"
    cp "${SCRIPT_DIR}/merge-generated.sh" "${dir}/scripts/lib/merge-generated.sh"
    chmod +x "${dir}/scripts/lib/merge-generated.sh"
    git -C "${dir}" config "merge.overture-generated.driver" "scripts/lib/merge-generated.sh %O %A %B %L %P"
  fi
}

commit_on() {
  local dir="$1" branch="$2" file="$3" text="$4"
  git -C "${dir}" checkout -q -B "${branch}" main
  printf '%s\n' "${text}" >> "${dir}/${file}"
  git -C "${dir}" commit -q -am "${branch}"
}

# --- a collision confined to the generated file is resolved, not a conflict ---
REPO_OK="${WORK}/only-generated"
make_repo "${REPO_OK}" with-driver
commit_on "${REPO_OK}" side-a docs/copy-inventory.md "A"
commit_on "${REPO_OK}" side-b docs/copy-inventory.md "B"

OUT="$(trial_merge_conflicts side-a side-b "${REPO_OK}" 2>/dev/null)"
STATUS=$?
assert_equals "a collision only on the generated file is RESOLVED" "${TRIAL_MERGE_RESOLVED}" "${STATUS}"
assert_empty "a resolved trial merge names no conflicted file" "${OUT}"

# --- a collision on an ordinary file is a real conflict, and it is NAMED ---
REPO_REAL="${WORK}/real-conflict"
make_repo "${REPO_REAL}" with-driver
git -C "${REPO_REAL}" checkout -q -B side-a main
printf 'A\n' >> "${REPO_REAL}/docs/copy-inventory.md"
printf 'A\n' >> "${REPO_REAL}/docs/contracts.md"
git -C "${REPO_REAL}" commit -q -am side-a
git -C "${REPO_REAL}" checkout -q -B side-b main
printf 'B\n' >> "${REPO_REAL}/docs/copy-inventory.md"
printf 'B\n' >> "${REPO_REAL}/docs/contracts.md"
git -C "${REPO_REAL}" commit -q -am side-b

OUT="$(trial_merge_conflicts side-a side-b "${REPO_REAL}" 2>/dev/null)"
STATUS=$?
assert_equals "a collision outside the generated files CONFLICTS" "${TRIAL_MERGE_CONFLICTS}" "${STATUS}"
assert_contains "the refusal can name the file that really collided" "${OUT}" "docs/contracts.md"
assert_not_contains "the file the driver settled is not reported as a conflict" "${OUT}" "docs/copy-inventory.md"

# --- a clone that never installed the driver gets no free pass ---
# The driver is registered per clone (scripts/install-git-hooks.sh), because merge.<name>.driver lives
# in the git config, which is not tracked. Without it git falls back to an ordinary text merge and the
# generated file really does conflict, so answering RESOLVED there would wave through a merge that is
# about to stop half way. The answer has to come from the trial merge rather than from the path list.
REPO_NO_DRIVER="${WORK}/no-driver"
make_repo "${REPO_NO_DRIVER}" without-driver
commit_on "${REPO_NO_DRIVER}" side-a docs/copy-inventory.md "A"
commit_on "${REPO_NO_DRIVER}" side-b docs/copy-inventory.md "B"

OUT="$(trial_merge_conflicts side-a side-b "${REPO_NO_DRIVER}" 2>/dev/null)"
STATUS=$?
assert_equals "without the driver installed the same collision CONFLICTS" "${TRIAL_MERGE_CONFLICTS}" "${STATUS}"
assert_contains "and it names the generated file, which really is unresolved here" "${OUT}" "docs/copy-inventory.md"

# --- a trial merge that could not run at all is UNMEASURED, never RESOLVED ---
# A ref that is not there, a git too old for --write-tree, a repository that is not one: all of them
# make merge-tree exit above 1, and all of them must read as "nobody measured" rather than as either
# verdict. An unmeasured check that reads as clean is the emptiest possible failure passing as the
# cleanest possible pass (L98).
OUT="$(trial_merge_conflicts side-a no-such-branch "${REPO_OK}" 2>/dev/null)"
STATUS=$?
assert_equals "a trial merge against a missing ref is UNMEASURED" "${TRIAL_MERGE_UNMEASURED}" "${STATUS}"

OUT="$(trial_merge_conflicts side-a side-b "${WORK}/not-a-repo" 2>/dev/null)"
STATUS=$?
assert_equals "a trial merge outside a repository is UNMEASURED" "${TRIAL_MERGE_UNMEASURED}" "${STATUS}"

# --- the three outcomes are distinct values ---
# Two outcomes a caller cannot tell apart are one outcome, whatever they are called (L260), and this
# helper's whole purpose is that a caller treats them differently.
assert_equals "resolved, conflicts and unmeasured are three different codes" "3" \
  "$(printf '%s\n%s\n%s\n' "${TRIAL_MERGE_RESOLVED}" "${TRIAL_MERGE_CONFLICTS}" "${TRIAL_MERGE_UNMEASURED}" | sort -u | wc -l | tr -d ' ')"

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "All generated-conflict checks passed."
