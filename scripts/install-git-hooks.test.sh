#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/shell-assertions.sh"

# Coverage for install-git-hooks.sh's install_hooks_into (#1251 Phase 3): it points git at the tracked
# hooks dir, and running it AGAIN leaves the same SINGLE value (idempotent, never an appended duplicate or
# an error). Drives a throwaway git repo, so no xcodegen and no touching this clone's config.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./install-git-hooks.sh
source "${SCRIPT_DIR}/install-git-hooks.sh"
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

TMP="$(mktemp -d)"
git -C "${TMP}" init -q

install_hooks_into "${TMP}"
assert_eq "installs core.hooksPath -> scripts/hooks" "scripts/hooks" "$(git -C "${TMP}" config core.hooksPath)"

# Idempotent: a second run leaves exactly the same single value, never a second appended entry.
install_hooks_into "${TMP}"
assert_eq "re-running keeps the same value" "scripts/hooks" "$(git -C "${TMP}" config core.hooksPath)"
assert_eq "exactly one hooksPath value (no duplicate appended)" \
  "1" "$(git -C "${TMP}" config --get-all core.hooksPath | grep -c '^')"

rm -rf "${TMP}"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "install-git-hooks.test.sh: all assertions passed"
  exit 0
else
  echo "install-git-hooks.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
