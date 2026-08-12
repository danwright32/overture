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

WORK="$(mktemp -d)"
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

# #2585: this script's remit is the CHECKOUT. Xcode's build output lives outside it and is reclaimed
# by scripts/reclaim-orphan-derived-data.sh, which every scripts/test-all.sh run already invokes. So
# tidy-checkout reports it and does not delete it, even under --apply. Asserted in both directions,
# because "reports it" alone would pass on a version that also deleted it.
if grep -q "Would reclaim 1 dead build folder" <<< "${OUTPUT}"; then
  assert "the run reports dead Xcode build output" "yes"
else
  assert "the run reports dead Xcode build output" "no"
  echo "${OUTPUT}" | sed 's/^/    /'
fi

if [[ -d "${DERIVED}/Overture-dead" ]]; then
  assert "--apply does not delete outside the checkout" "yes"
else
  assert "--apply does not delete outside the checkout" "no"
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

PATH="${WORK}/bin:${PATH}" TIDY_CHECKOUT_REPO_ROOT="${REPO}" \
  "${SCRIPT_DIR}/tidy-checkout.sh" >/dev/null 2>&1

if git -C "${REPO}" for-each-ref --format='%(refname:short)' refs/heads/ | grep -qx "shipped-again"; then
  assert "a dry run deletes nothing, even a branch it would remove" "yes"
else
  assert "a dry run deletes nothing, even a branch it would remove" "no"
fi

echo
if [[ ${FAILURES} -eq 0 ]]; then
  echo "All tidy-checkout.sh driver fixtures passed."
  exit 0
else
  echo "${FAILURES} tidy-checkout.sh driver fixture(s) failed."
  exit 1
fi
