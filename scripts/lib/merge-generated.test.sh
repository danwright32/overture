#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/shell-assertions.sh"

# #2557: two checked-in files here are GENERATED from the source, docs/copy-inventory.md and
# mac/Overture.xcodeproj/project.pbxproj, so any two branches that touch the app's wording or its file
# list conflict on them by construction. The resolution is always the same and carries no decision:
# neither side's text is anybody's to write, and the merged tree's own generator settles it.
#
# Measured 2026-08-11: two branches in a row each conflicted on the inventory against a main that had
# moved, roughly twelve minutes apiece, and neither conflict carried any information.
#
# Every case below drives a REAL git merge in a throwaway repo with the driver configured exactly as
# scripts/install-git-hooks.sh configures it, rather than calling the driver by hand. A driver that
# works when called directly and is not actually wired to the path is the failure this is written to
# avoid (L3).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Sourced ONCE, here, and errexit turned straight back off. install-git-hooks.sh opens with
# `set -euo pipefail`, and sourcing a script adopts its options, so without the `set +e` below the first
# deliberately failing case in this file would kill the run instead of being recorded as a check that
# passed. It exited 1 silently after the ninth assertion the first time this was written.
# shellcheck source=../install-git-hooks.sh
source "${REPO_ROOT}/scripts/install-git-hooks.sh"
set +e

FAILURES=0
TMP="$(fixture_scratch_dir)"
trap 'rm -rf "${TMP}"' EXIT

# A throwaway repo carrying this repo's real .gitattributes and the real driver, wired by the real
# installer. Nothing here is a copy of the rules under test.
make_repo() {
  local dir="$1"
  mkdir -p "${dir}"
  git -C "${dir}" init -q -b main
  git -C "${dir}" config user.email "fixture@example.com"
  git -C "${dir}" config user.name "Fixture"
  cp "${REPO_ROOT}/.gitattributes" "${dir}/.gitattributes"
  mkdir -p "${dir}/scripts/lib" "${dir}/docs" "${dir}/mac/Overture.xcodeproj"
  cp "${REPO_ROOT}/scripts/lib/merge-generated.sh" "${dir}/scripts/lib/merge-generated.sh"
  chmod +x "${dir}/scripts/lib/merge-generated.sh"
  install_generated_merge_driver_into "${dir}"
}

# Both sides change one file away from a shared ancestor, which is the only situation git calls a merge
# driver in at all.
diverge_on() {
  local dir="$1" path="$2"
  mkdir -p "${dir}/$(dirname "${path}")"
  printf 'ancestor\n' > "${dir}/${path}"
  git -C "${dir}" add -A
  git -C "${dir}" commit -qm "ancestor"

  git -C "${dir}" checkout -q -b other
  printf 'what the other branch generated\n' > "${dir}/${path}"
  git -C "${dir}" commit -qam "other side"

  git -C "${dir}" checkout -q main
  printf 'what this branch generated\n' > "${dir}/${path}"
  git -C "${dir}" commit -qam "our side"
}

merge_other() {
  local dir="$1"
  git -C "${dir}" merge --no-edit other > "${dir}/.merge-output" 2>&1
  echo "$?"
}

# --- the copy inventory ------------------------------------------------------------------------------

REPO_A="${TMP}/inventory"
make_repo "${REPO_A}"
diverge_on "${REPO_A}" "docs/copy-inventory.md"
RC="$(merge_other "${REPO_A}")"

assert_equals "a generated inventory on both sides merges without stopping" "0" "${RC}"
assert_not_contains "the merged inventory carries no conflict markers" \
  "$(cat "${REPO_A}/docs/copy-inventory.md")" "<<<<<<<"
assert_empty "git is left with nothing unmerged" "$(git -C "${REPO_A}" diff --name-only --diff-filter=U)"

# --- the Xcode project -------------------------------------------------------------------------------

REPO_B="${TMP}/pbxproj"
make_repo "${REPO_B}"
diverge_on "${REPO_B}" "mac/Overture.xcodeproj/project.pbxproj"
RC="$(merge_other "${REPO_B}")"

assert_equals "a generated project file on both sides merges without stopping" "0" "${RC}"
assert_not_contains "the merged project file carries no conflict markers" \
  "$(cat "${REPO_B}/mac/Overture.xcodeproj/project.pbxproj")" "<<<<<<<"
assert_empty "git is left with nothing unmerged either" \
  "$(git -C "${REPO_B}" diff --name-only --diff-filter=U)"

# --- everything else still conflicts -----------------------------------------------------------------
#
# The point of the whole change is that a conflict carrying no DECISION is auto-resolved. A conflict in
# a file somebody actually writes still has to stop and be read, and a driver wired too widely would
# swallow exactly those. This is the case that makes the two above mean something.

REPO_C="${TMP}/handwritten"
make_repo "${REPO_C}"
diverge_on "${REPO_C}" "mac/Overture/Domain/Ranker.swift"
RC="$(merge_other "${REPO_C}")"

assert_equals "a hand-written source file on both sides still stops the merge" "1" "${RC}"
assert_contains "and the conflict is reported" "$(cat "${REPO_C}/.merge-output")" "CONFLICT"

# A doc that reads as generated but is written by hand must not be swept in either.
REPO_D="${TMP}/handwritten-doc"
make_repo "${REPO_D}"
diverge_on "${REPO_D}" "docs/contracts.md"
RC="$(merge_other "${REPO_D}")"

assert_equals "a hand-written doc on both sides still stops the merge" "1" "${RC}"

# --- the driver refuses a path it does not own -------------------------------------------------------
#
# Called with a path outside its two, the driver must report a conflict rather than silently picking a
# side. A driver that resolves anything it is pointed at turns a mis-typed .gitattributes line into
# silent data loss, and nothing downstream would ever report it.

O="${TMP}/ancestor"; A="${TMP}/ours"; B="${TMP}/theirs"
printf 'ancestor\n' > "${O}"; printf 'ours\n' > "${A}"; printf 'theirs\n' > "${B}"
"${REPO_ROOT}/scripts/lib/merge-generated.sh" "${O}" "${A}" "${B}" 7 "src/something-hand-written.swift" \
  > "${TMP}/refusal-output" 2>&1
REFUSAL_RC="$?"

assert_equals "the driver refuses a path outside the generated pair" "1" "${REFUSAL_RC}"
assert_equals "and leaves that file exactly as it found it" "ours" "$(cat "${A}")"
assert_contains "and says which path it refused" "$(cat "${TMP}/refusal-output")" \
  "src/something-hand-written.swift"

# --- the installer -----------------------------------------------------------------------------------

REPO_E="${TMP}/installer"
mkdir -p "${REPO_E}"
git -C "${REPO_E}" init -q -b main
install_generated_merge_driver_into "${REPO_E}"

assert_contains "the installer registers the driver" \
  "$(git -C "${REPO_E}" config --get merge.overture-generated.driver)" "merge-generated.sh"
assert_contains "and gives it a name git can print" \
  "$(git -C "${REPO_E}" config --get merge.overture-generated.name)" "generated"

install_generated_merge_driver_into "${REPO_E}"
assert_equals "installing twice leaves exactly one driver registered" "1" \
  "$(git -C "${REPO_E}" config --get-all merge.overture-generated.driver | wc -l | tr -d ' ')"

# --- the wiring in this repo -------------------------------------------------------------------------
#
# Derived from the driver's own list rather than repeated here, so the two cannot drift: whatever paths
# the driver claims to own must be the paths .gitattributes actually sends it (L41).

GENERATED_PATHS="$("${REPO_ROOT}/scripts/lib/merge-generated.sh" --paths)"
assert_contains "the driver owns the copy inventory" "${GENERATED_PATHS}" "docs/copy-inventory.md"
assert_contains "the driver owns the Xcode project" "${GENERATED_PATHS}" \
  "mac/Overture.xcodeproj/project.pbxproj"

while IFS= read -r path; do
  [[ -n "${path}" ]] || continue
  ATTR="$(git -C "${REPO_ROOT}" check-attr merge -- "${path}")"
  assert_contains "git sends ${path} to the driver" "${ATTR}" "merge: overture-generated"
done <<< "${GENERATED_PATHS}"

# --- every generated copy document reaches the driver, not just the ones somebody remembered (#3221) ---
#
# The loop above walks the driver's OWN list, so it can only ever confirm that what the driver claims is
# what git sends. It is blind in the direction that actually went wrong: a document that is generated and
# was never added to the list is not in either half, so both agree and nothing notices (L96).
#
# The other side of the question already has a definition, and it is the one the merge paths rebuild
# from, so this is derived from that rather than written out again (L41). #2946 added
# docs/outbound-copy.md and docs/copy-surfaces.md to it and neither reached .gitattributes, which is the
# defect: two branches that both change the app's wording still hand a person a conflict in text neither
# of them wrote, which is the exact cost #2557 was built to remove.
# shellcheck source=./copy-docs-rebuild.sh
source "${REPO_ROOT}/scripts/lib/copy-docs-rebuild.sh"
assert_equals "there really are generated copy documents to check, so this is not passing over nothing" \
  "0" "$([[ ${#COPY_DOC_PATHS[@]} -gt 0 ]] && echo 0 || echo 1)"
for doc in "${COPY_DOC_PATHS[@]}"; do
  assert_contains "the driver owns the generated document ${doc}" "${GENERATED_PATHS}" "${doc}"
done

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All merge-generated.sh fixtures passed."
  exit 0
else
  echo "${FAILURES} merge-generated.sh fixture(s) failed."
  exit 1
fi
