#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/shell-assertions.sh"

# #2301: the DRIVER, not the decision. `scripts/lib/checkout-tidy.test.sh` has 31 fixtures pinning
# which branches and worktrees may be removed, including every case that must be kept. Nothing covered
# the part that turns a verdict into `git branch -D`, which is the piece that was wrong twice while it
# was being written (an expensive containment check paid for on every branch, and a quadratic
# emptiness test).
#
# So this builds a throwaway repository, runs the REAL script with --apply against it, and asserts what
# survived. A future edit that hands the wrong verdict to the delete loop, or inverts a case, leaves the
# pure fixtures green and fails here.
#
# `gh` is stubbed to FAIL, which is deliberate rather than a shortcut: the script's documented fallback
# when it cannot read PR history is to prove containment with `git cherry`, and that is the harder path
# and the only one available on a repository with no remote.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

assert() {
  local desc="$1" condition="$2"
  if [[ "${condition}" == "yes" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    FAILURES=$((FAILURES + 1))
  fi
}

WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${WORK}"' EXIT

# A stub gh that always fails, on PATH ahead of the real one.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "${WORK}/bin/gh"

REPO="${WORK}/repo"
mkdir -p "${REPO}"
git -C "${REPO}" init -q -b main
git -C "${REPO}" config user.email "fixture@example.test"
git -C "${REPO}" config user.name "Fixture"

echo "one" > "${REPO}/file.txt"
git -C "${REPO}" add file.txt
git -C "${REPO}" commit -qm "base"

# A SHIPPED branch: its change is already in main under a different commit, which is what a squash
# merge leaves behind and why `git branch --merged` recognises almost none of them here.
git -C "${REPO}" checkout -q -b shipped-work
echo "shipped change" >> "${REPO}/file.txt"
git -C "${REPO}" commit -qam "shipped change"
PATCH="${WORK}/shipped.patch"
git -C "${REPO}" format-patch -1 --stdout > "${PATCH}"
git -C "${REPO}" checkout -q main
git -C "${REPO}" am -q < "${PATCH}"

# An UNSHIPPED branch: its commit exists nowhere else.
git -C "${REPO}" checkout -q -b unshipped-work
echo "unshipped change" >> "${REPO}/other.txt"
git -C "${REPO}" add other.txt
git -C "${REPO}" commit -qm "unshipped change"
git -C "${REPO}" checkout -q main

# A throwaway Xcode build root holding one dead folder, so the run below reports the real thing
# without any chance of reading or writing ~/Library/Developer/Xcode/DerivedData (#2585, L2).
DERIVED="${WORK}/derived"
mkdir -p "${DERIVED}/Overture-dead"
cat > "${DERIVED}/Overture-dead/info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>WorkspacePath</key>
	<string>${WORK}/a-worktree-that-is-gone/mac/Overture.xcodeproj</string>
</dict>
</plist>
PLIST

OUTPUT="$(PATH="${WORK}/bin:${PATH}" TIDY_CHECKOUT_REPO_ROOT="${REPO}" \
  XCODE_DERIVED_DATA_ROOT="${DERIVED}" \
  "${SCRIPT_DIR}/tidy-checkout.sh" --apply 2>&1)"

# #2585: Xcode's build output is the one cache that lives OUTSIDE the checkout, keyed by the
# checkout's path, so removing a worktree above reclaims everything it held except that. Dan's call,
# 2026-08-12: --apply means clean up everything it just showed, so this deletes it rather than
# reporting it and leaving it. Asserted in both directions, because "reports it" alone would pass on a
# version that reported and did nothing, which is what it did when first written.
if grep -q "Reclaimed 1 dead build folder" <<< "${OUTPUT}"; then
  assert "the run reports dead Xcode build output" "yes"
else
  assert "the run reports dead Xcode build output" "no"
  echo "${OUTPUT}" | sed 's/^/    /'
fi

if [[ -d "${DERIVED}/Overture-dead" ]]; then
  assert "--apply reclaims dead Xcode build output" "no"
else
  assert "--apply reclaims dead Xcode build output" "yes"
fi

BRANCHES="$(git -C "${REPO}" for-each-ref --format='%(refname:short)' refs/heads/)"

# The whole point, in both directions. Either one alone could pass for the wrong reason: a script that
# deleted nothing would keep the unshipped branch, and one that deleted everything would remove the
# shipped one.
if grep -qx "shipped-work" <<< "${BRANCHES}"; then
  assert "a branch whose change is already in main is deleted" "no"
else
  assert "a branch whose change is already in main is deleted" "yes"
fi

if grep -qx "unshipped-work" <<< "${BRANCHES}"; then
  assert "a branch holding work that is nowhere else SURVIVES" "yes"
else
  assert "a branch holding work that is nowhere else SURVIVES" "no"
  echo "  the driver deleted unshipped work, which is the one thing it must never do"
  echo "${OUTPUT}" | sed 's/^/    /'
fi

# main itself is never a candidate, whatever else happens.
if grep -qx "main" <<< "${BRANCHES}"; then
  assert "main survives" "yes"
else
  assert "main survives" "no"
fi

# And the run said what it did, so a person reading the output can tell it acted rather than no-opped.
if grep -q "delete shipped-work" <<< "${OUTPUT}"; then
  assert "the run names the branch it deleted" "yes"
else
  assert "the run names the branch it deleted" "no"
fi

# A DRY RUN deletes nothing, which is the default and the thing standing between a typo and a loss.
git -C "${REPO}" checkout -q -b shipped-again
echo "second shipped change" >> "${REPO}/file.txt"
git -C "${REPO}" commit -qam "second shipped change"
git -C "${REPO}" format-patch -1 --stdout > "${WORK}/second.patch"
git -C "${REPO}" checkout -q main
git -C "${REPO}" am -q < "${WORK}/second.patch"

# A second dead build folder, so the dry run below has something it COULD take. Without one, the
# assertion that it takes nothing would pass on an empty root and prove nothing.
mkdir -p "${DERIVED}/Overture-dead-again"
cat > "${DERIVED}/Overture-dead-again/info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>WorkspacePath</key>
	<string>${WORK}/another-worktree-that-is-gone/mac/Overture.xcodeproj</string>
</dict>
</plist>
PLIST

# XCODE_DERIVED_DATA_ROOT on this call too, not only the one above: without it a dry run would read
# the real ~/Library/Developer/Xcode/DerivedData, and a fixture must be structurally unable to reach
# it whichever path through the script it takes (L2).
PATH="${WORK}/bin:${PATH}" TIDY_CHECKOUT_REPO_ROOT="${REPO}" \
  XCODE_DERIVED_DATA_ROOT="${DERIVED}" \
  "${SCRIPT_DIR}/tidy-checkout.sh" >/dev/null 2>&1

if grep -qx "shipped-again" <<< "$(git -C "${REPO}" for-each-ref --format='%(refname:short)' refs/heads/)"; then
  assert "a dry run deletes nothing, even a branch it would remove" "yes"
else
  assert "a dry run deletes nothing, even a branch it would remove" "no"
fi

if [[ -d "${DERIVED}/Overture-dead-again" ]]; then
  assert "a dry run leaves dead build output alone too" "yes"
else
  assert "a dry run leaves dead build output alone too" "no"
fi

# --- #2842: a worktree something is still working in is kept, whatever its branch says ---
#
# Driven end to end, and in BOTH directions, because either half alone passes for the wrong reason: a
# script that removed no worktree at all would keep the live one, and the version this replaces removed
# both. Both worktrees below sit on SHIPPED branches, so by branch state alone both are removable and
# the only thing that can separate them is whether something is working in them.
#
# The idle one is backdated with `touch`, rather than the live one being left to real time, so the test
# does not depend on how long the rest of this fixture takes to run (L130).

make_shipped_branch() {
  local name="$1"
  git -C "${REPO}" checkout -q -b "${name}" main
  echo "${name} change" > "${REPO}/${name}.txt"
  git -C "${REPO}" add "${name}.txt"
  git -C "${REPO}" commit -qm "${name} change"
  git -C "${REPO}" format-patch -1 --stdout > "${WORK}/${name}.patch"
  git -C "${REPO}" checkout -q main
  git -C "${REPO}" am -q < "${WORK}/${name}.patch"
}

make_shipped_branch "live-agent-work"
make_shipped_branch "idle-agent-work"

LIVE_WT="${WORK}/live-worktree"
IDLE_WT="${WORK}/idle-worktree"
git -C "${REPO}" worktree add -q "${LIVE_WT}" live-agent-work
git -C "${REPO}" worktree add -q "${IDLE_WT}" idle-agent-work

# Nothing has written in the idle one for a long time. `find -exec` rather than a single touch, since
# the probe stops at the FIRST file newer than the cutoff and any one of them would answer for it.
find "${IDLE_WT}" -exec touch -t 202601010000 {} \; 2>/dev/null
touch "${LIVE_WT}/scratch.txt"

WT_OUTPUT="$(PATH="${WORK}/bin:${PATH}" TIDY_CHECKOUT_REPO_ROOT="${REPO}" \
  XCODE_DERIVED_DATA_ROOT="${DERIVED}" \
  "${SCRIPT_DIR}/tidy-checkout.sh" --apply 2>&1)"

if [[ -d "${LIVE_WT}" ]]; then
  assert "a worktree written to moments ago SURVIVES, though its branch shipped" "yes"
else
  assert "a worktree written to moments ago SURVIVES, though its branch shipped" "no"
  echo "  the driver deleted a directory something was working in, which is what #2842 is about"
  echo "${WT_OUTPUT}" | sed 's/^/    /'
fi

if [[ -d "${IDLE_WT}" ]]; then
  assert "an idle worktree on a shipped branch is still removed" "no"
  echo "${WT_OUTPUT}" | sed 's/^/    /'
else
  assert "an idle worktree on a shipped branch is still removed" "yes"
fi

# And it says WHY it kept it, which is the distinction that was invisible when this was measured: a
# worktree kept because an agent is in it reads identically to one kept because its branch has not
# landed unless the output separates them.
if grep -q "live: locked, or written to in the last" <<< "${WT_OUTPUT}"; then
  assert "the run says the worktree was kept because something is working in it" "yes"
else
  assert "the run says the worktree was kept because something is working in it" "no"
  echo "${WT_OUTPUT}" | sed 's/^/    /'
fi

echo
if [[ ${FAILURES} -eq 0 ]]; then
  echo "All tidy-checkout.sh driver fixtures passed."
  exit 0
else
  echo "${FAILURES} tidy-checkout.sh driver fixture(s) failed."
  exit 1
fi
