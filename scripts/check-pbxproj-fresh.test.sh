#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/shell-assertions.sh"

# Pure-function coverage for check-pbxproj-fresh.sh's pbxproj_freshness_verdict (Phase 1 of #1251,
# closes #1368). The real gate runs xcodegen and asks git whether the committed project.pbxproj changed;
# this fixture drives the DECISION over those two facts (does the installed xcodegen match the pinned
# version, and does a fresh regen match the committed file) so it runs anywhere, including CI where no
# xcodegen or Xcode exists.
#
# The load-bearing case is `stale`: a committed pbxproj that a fresh regen would change MUST BLOCK (exit
# 1) with a message that says "stale", never pass. That is the exact #1368 hole (the merge scripts
# regenerated the stale file and shipped it). If the verdict stops blocking that, this fixture goes red,
# which is the mutation this guard must survive. The version-mismatch case must emit its OWN distinct
# "cannot verify" verdict (exit 2), never a false "stale", so cross-machine byte drift can't masquerade
# as staleness.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./check-pbxproj-fresh.sh
source "${SCRIPT_DIR}/check-pbxproj-fresh.sh"
# check-pbxproj-fresh.sh's own `set -euo pipefail` is now active. Turn errexit off so one failing
# assertion (or a non-zero verdict return we are asserting ON) doesn't abort the rest of the run.
set +e

FAILURES=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected to contain: ${needle}"
    echo "  actual: ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected NOT to contain: ${needle}"
    echo "  actual: ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

# Runs the verdict, capturing its stderr message in MSG and its exit code in CODE. The fourth argument
# (whether the working tree already held the fresh regen) and the fifth (whether that regen is STAGED)
# are optional so the version-mismatch and absent cases can omit them, matching how the real gate calls
# the verdict on its early-return paths.
run_verdict() {
  MSG="$(pbxproj_freshness_verdict "$1" "$2" "$3" "${4:-false}" "${5:-false}" 2>&1)"
  CODE=$?
}

# FRESH: installed matches pinned and a fresh regen matches the committed file. Passes silently (exit 0).
run_verdict "2.45.3" "2.45.3" "true"
assert_eq "fresh: exit 0" "0" "${CODE}"

# STALE (the mutation this guard exists to catch): versions match, a fresh regen would change the committed
# pbxproj, and the working tree did NOT already hold that regen (the genuinely-stale commit). MUST block
# with exit 1 and a message that says stale and tells the operator to regenerate and commit.
run_verdict "2.45.3" "2.45.3" "false" "false"
assert_eq "stale: exit 1 (BLOCK)" "1" "${CODE}"
assert_contains "stale: message says stale" "${MSG}" "stale"
assert_contains "stale: message says to regenerate" "${MSG}" "xcodegen generate"

# REGENERATED-BUT-NOT-COMMITTED (#1480): versions match and a fresh regen still differs from the COMMITTED
# file, but the working tree already held exactly that fresh output before this check ran. HEAD is behind
# either way, so it MUST still block (exit 1); but the operator already regenerated, so the bare
# "regenerate and commit" sends them in a loop asking for work already done. Since #2355 the check puts the
# tree back from a snapshot, so their regeneration is still in front of them and the message must say so
# rather than describing a revert that no longer happens. It must also NOT tell them the committed file is
# stale as if they had never touched it.
run_verdict "2.45.3" "2.45.3" "false" "true"
assert_eq "not-committed: exit 1 (BLOCK)" "1" "${CODE}"
assert_contains "not-committed: message says not committed" "${MSG}" "not committed"
assert_contains "not-committed: message says the regen is still there" "${MSG}" "untouched"
assert_not_contains "not-committed: does not describe a revert that no longer happens" "${MSG}" "reverted"
assert_not_contains "not-committed: does NOT call the file stale" "${MSG}" "is stale"
assert_contains "not-committed: still points at a commit" "${MSG}" "git commit"

# VERSION MISMATCH: the installed xcodegen is not the pinned one, so freshness cannot be verified at all
# (byte drift between versions would look like staleness). MUST be its own outcome (exit 2) with a
# "cannot verify" message, and MUST NOT claim the file is stale, regardless of the regen-match flag.
run_verdict "2.44.1" "2.45.3" "false"
assert_eq "mismatch: exit 2 (cannot verify)" "2" "${CODE}"
assert_contains "mismatch: message says cannot verify" "${MSG}" "cannot verify"
assert_contains "mismatch: message names version mismatch" "${MSG}" "version mismatch"
assert_not_contains "mismatch: does NOT masquerade as stale" "${MSG}" "is stale"

# A missing xcodegen ("absent") is a version mismatch too: it cannot verify, exit 2, never a false stale.
run_verdict "absent" "2.45.3" "true"
assert_eq "absent: exit 2 (cannot verify)" "2" "${CODE}"
assert_contains "absent: message says cannot verify" "${MSG}" "cannot verify"

# REGENERATED AND STAGED (#2817): the same #1480 shape with the regen `git add`ed. It MUST still block,
# and it must NOT repeat the unstaged message, which tells the operator nothing is staged and sends them
# to redo a regeneration that is sitting in the index (L11: distinct causes get distinct messages).
run_verdict "2.45.3" "2.45.3" "false" "true" "true"
assert_eq "staged: exit 1 (BLOCK)" "1" "${CODE}"
assert_contains "staged: message says it is staged" "${MSG}" "and STAGED"
assert_contains "staged: message says not committed" "${MSG}" "not committed"
assert_not_contains "staged: does NOT claim nothing is staged" "${MSG}" "nothing is staged"
assert_not_contains "staged: does NOT call the file stale" "${MSG}" "is stale"

# --- the REAL gate, over a throwaway git repo (#2817) -----------------------------------------------
#
# Everything above drives the pure verdict, which is handed its facts already decided. #2817 lived in
# the code that DECIDES one of them: check_pbxproj_fresh asked `git diff --quiet -- <path>`, which
# compares the working tree against the INDEX rather than against HEAD, so a regeneration that was
# staged and not committed (exactly what scripts/hooks/post-merge leaves behind) read as FRESH and the
# gate returned 0 over a stale commit.
#
# The script's own header names that state as a BLOCK outcome, and no test had ever BUILT it (L151):
# every outcome a guard's contract enumerates needs a test that PRODUCES it, not merely one that passes.
# So this section constructs each state in a real repository and runs the real function over it.
#
# xcodegen is stubbed rather than run: the real one needs a real Xcode project, and what is under test
# is the git comparison, not the generator.

GATE_WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${GATE_WORK}"' EXIT

STUB_BIN="${GATE_WORK}/bin"
mkdir -p "${STUB_BIN}"
cat > "${STUB_BIN}/xcodegen" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "Version: ${STUB_XCODEGEN_VERSION}"
  exit 0
fi
cp "${STUB_XCODEGEN_OUTPUT}" "Overture.xcodeproj/project.pbxproj"
STUB
chmod +x "${STUB_BIN}/xcodegen"
export STUB_XCODEGEN_VERSION="${XCODEGEN_PINNED_VERSION}"

# make_gate_repo <name> <committed> <working-tree> <stage|no-stage>: a repository holding the given
# project file at HEAD, the given one in the working tree, and the working-tree one staged or not.
# Its own repo, in TMPDIR, never the real checkout.
make_gate_repo() {
  local name="$1" committed="$2" worktree="$3" stage="$4"
  local dir="${GATE_WORK}/${name}"
  mkdir -p "${dir}/mac/Overture.xcodeproj"
  git init -q "${dir}" >/dev/null 2>&1
  printf 'name: Overture\n' > "${dir}/mac/project.yml"
  printf '%s\n' "${committed}" > "${dir}/mac/Overture.xcodeproj/project.pbxproj"
  # A tracked neighbour inside the same directory, because the restore covers the whole .xcodeproj and
  # an UNTRACKED file would survive `git checkout --` on its own, making that assertion vacuous.
  printf 'committed scheme\n' > "${dir}/mac/Overture.xcodeproj/scheme.xcscheme"
  git -C "${dir}" add -A >/dev/null 2>&1
  git -C "${dir}" -c user.email=fixture@example.com -c user.name=fixture \
    commit -q --no-verify -m "base" >/dev/null 2>&1
  printf '%s\n' "${worktree}" > "${dir}/mac/Overture.xcodeproj/project.pbxproj"
  if [[ "${stage}" == "stage" ]]; then
    git -C "${dir}" add -- mac/Overture.xcodeproj/project.pbxproj >/dev/null 2>&1
  fi
  echo "${dir}"
}

# Runs the real gate over one repo, with the stub xcodegen producing <fresh> as its output.
run_gate() {
  local dir="$1" fresh="$2" saved_path="${PATH}"
  printf '%s\n' "${fresh}" > "${GATE_WORK}/fresh.txt"
  export STUB_XCODEGEN_OUTPUT="${GATE_WORK}/fresh.txt"
  PATH="${STUB_BIN}:${PATH}"
  MSG="$(check_pbxproj_fresh "${dir}" 2>&1)"
  CODE=$?
  PATH="${saved_path}"
}

# THE #2817 CASE. HEAD holds the old project file; the regeneration is in the working tree AND staged.
# `git diff --quiet -- <path>` sees working tree and index agreeing and reports clean, so the gate used
# to return 0 here. It must BLOCK: the COMMIT is what a merge carries, and the commit is behind.
STAGED_REPO="$(make_gate_repo staged "OLD PROJECT FILE" "FRESH PROJECT FILE" stage)"
run_gate "${STAGED_REPO}" "FRESH PROJECT FILE"
assert_eq "gate, staged regen: exit 1 (BLOCK), not a false FRESH" "1" "${CODE}"
assert_contains "gate, staged regen: message BLOCKs" "${MSG}" "BLOCK"
assert_contains "gate, staged regen: message says not committed" "${MSG}" "not committed"
assert_contains "gate, staged regen: message says it is staged" "${MSG}" "and STAGED"
# The gate puts the tree back after regenerating, from a snapshot rather than from git (#2355), so a
# staged regeneration survives both in the tree and in the index. The message tells the operator to
# commit it, so that has to be true.
assert_contains "gate, staged regen: the staged regen is still staged afterwards" \
  "$(git -C "${STAGED_REPO}" diff --cached --name-only)" "mac/Overture.xcodeproj/project.pbxproj"

# A regeneration in the working tree that was never staged: still a BLOCK, and still the #1480 message,
# which since #2355 tells the operator their regen is still there rather than that it was thrown away.
UNSTAGED_REPO="$(make_gate_repo unstaged "OLD PROJECT FILE" "FRESH PROJECT FILE" no-stage)"
run_gate "${UNSTAGED_REPO}" "FRESH PROJECT FILE"
assert_eq "gate, unstaged regen: exit 1 (BLOCK)" "1" "${CODE}"
assert_contains "gate, unstaged regen: message says not committed" "${MSG}" "not committed"
assert_contains "gate, unstaged regen: message says the regen is still there" "${MSG}" "untouched"

# A genuinely stale commit: nobody has regenerated, so the working tree matches HEAD and a fresh regen
# differs from both. Blocks, and calls the file stale.
STALE_REPO="$(make_gate_repo stale "OLD PROJECT FILE" "OLD PROJECT FILE" no-stage)"
run_gate "${STALE_REPO}" "FRESH PROJECT FILE"
assert_eq "gate, stale commit: exit 1 (BLOCK)" "1" "${CODE}"
assert_contains "gate, stale commit: message says stale" "${MSG}" "is stale"
assert_eq "gate, stale commit: the tree is left as it was found" "OLD PROJECT FILE" \
  "$(cat "${STALE_REPO}/mac/Overture.xcodeproj/project.pbxproj")"

# The committed file already matches a fresh regen: the only outcome that may pass.
FRESH_REPO="$(make_gate_repo fresh "FRESH PROJECT FILE" "FRESH PROJECT FILE" no-stage)"
run_gate "${FRESH_REPO}" "FRESH PROJECT FILE"
assert_eq "gate, fresh commit: exit 0" "0" "${CODE}"

# --- the caller's uncommitted work survives the check (#2355) ---------------------------------------
#
# The check has to regenerate to compare, which overwrites whatever is in the working tree, and it then
# put the tree back with `git checkout --`, which restores from the INDEX and so destroys any
# uncommitted change under mac/Overture.xcodeproj. On a FRESH verdict it said nothing at all, and the
# next `git status` read as "nothing needed regenerating" rather than "your work was reverted".
#
# Measured 2026-08-09 during #1571: a regenerated project file was reverted this way and a new test file
# consequently sat outside the build for a full suite run, which passed green with those tests absent.
# L5: never destroy good state. So the tree is snapshotted before the regen and put back from the
# SNAPSHOT, which leaves it exactly as the caller left it whatever the verdict turns out to be.

# A hand edit the caller had not committed, over a verdict that passes. Nothing warns here, so if the
# edit does not survive, it is gone with no trace anywhere.
EDITED_REPO="$(make_gate_repo edited "FRESH PROJECT FILE" "HAND EDITED, NOT COMMITTED" no-stage)"
run_gate "${EDITED_REPO}" "FRESH PROJECT FILE"
assert_eq "gate, uncommitted edit: the caller's uncommitted work survives" "HAND EDITED, NOT COMMITTED" \
  "$(cat "${EDITED_REPO}/mac/Overture.xcodeproj/project.pbxproj")"

# Anything else the caller had under mac/Overture.xcodeproj survives too: the restore covered the whole
# directory, so a scheme edited beside the project file was destroyed by the same line.
SCHEME_REPO="$(make_gate_repo scheme "FRESH PROJECT FILE" "FRESH PROJECT FILE" no-stage)"
printf 'edited scheme\n' > "${SCHEME_REPO}/mac/Overture.xcodeproj/scheme.xcscheme"
run_gate "${SCHEME_REPO}" "FRESH PROJECT FILE"
assert_eq "gate, uncommitted scheme: survives too" "edited scheme" \
  "$(cat "${SCHEME_REPO}/mac/Overture.xcodeproj/scheme.xcscheme" 2>/dev/null)"

# And the regeneration the caller made themselves survives, which is what closes the #1480 loop rather
# than explaining it: they are told to commit what is already in front of them, not to redo it.
KEPT_REPO="$(make_gate_repo kept "OLD PROJECT FILE" "FRESH PROJECT FILE" no-stage)"
run_gate "${KEPT_REPO}" "FRESH PROJECT FILE"
assert_eq "gate, unstaged regen: still BLOCKs" "1" "${CODE}"
assert_eq "gate, unstaged regen: the regen is still there afterwards" "FRESH PROJECT FILE" \
  "$(cat "${KEPT_REPO}/mac/Overture.xcodeproj/project.pbxproj")"
assert_not_contains "gate, unstaged regen: is not described as reverted" "${MSG}" "reverted"

# A snapshot that cannot be TAKEN refuses, and destroys nothing. This is the failure path of the
# protection itself: if it ever regenerated over work it could not put back, it would be doing the exact
# damage it was added to stop, and it would do it while reporting a freshness verdict.
UNREADABLE_REPO="$(make_gate_repo unreadable "FRESH PROJECT FILE" "HAND EDITED, NOT COMMITTED" no-stage)"
chmod 000 "${UNREADABLE_REPO}/mac/Overture.xcodeproj"
run_gate "${UNREADABLE_REPO}" "FRESH PROJECT FILE"
chmod 755 "${UNREADABLE_REPO}/mac/Overture.xcodeproj"
assert_eq "gate, unsnapshotable tree: exit 2 (cannot verify)" "2" "${CODE}"
assert_contains "gate, unsnapshotable tree: says it cannot verify" "${MSG}" "cannot verify"
assert_contains "gate, unsnapshotable tree: names the snapshot as the reason" "${MSG}" "snapshot"
assert_eq "gate, unsnapshotable tree: destroyed nothing" "HAND EDITED, NOT COMMITTED" \
  "$(cat "${UNREADABLE_REPO}/mac/Overture.xcodeproj/project.pbxproj")"

# Nothing is left lying beside the project directory afterwards, on every path these scenarios drive.
# The one path that deliberately keeps a copy is a swap that could not complete, where the copy IS the
# caller's work and the message names it; no scenario here reaches that, so this stays an absolute.
assert_empty "gate: no staging directory is left behind" \
  "$(ls -d "${GATE_WORK}"/*/mac/.Overture.xcodeproj.restore 2>/dev/null)"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "check-pbxproj-fresh.test.sh: all assertions passed"
  exit 0
else
  echo "check-pbxproj-fresh.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
