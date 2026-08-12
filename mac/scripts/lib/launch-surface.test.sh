#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"

# #1120: the `overture` launch surface must pin the installed bundle by PATH, never bare-open the
# overture:// URL. A bare `open overture://show` lets LaunchServices route the scheme to whichever
# registered com.danwright.overture copy it picks, so a stray Release bundle could catch the launch and
# spawn a duplicate the store lock then refuses. overture_launch_open_args emits `open` arguments that
# force the URL onto the installed bundle (`open -a <installed> overture://show`). These checks pin that.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

pass() { echo "ok - $1"; }
fail() {
  echo "FAIL - $1"
  [ -n "${2:-}" ] && echo "  $2"
  FAILURES=$((FAILURES + 1))
}

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/launch-surface.sh"

# Read the emitted args (one per line) into an array, tolerating spaces in a path.
ARGS=()
while IFS= read -r a; do ARGS+=("$a"); done < <(overture_launch_open_args "/Applications/Overture.app")

# 1. It pins the bundle by PATH: the first arg is `-a`, not the bare URL. This is the whole point (a bare
#    URL open is exactly the scheme-routing #1120 removes), so this is the load-bearing assertion.
if [[ "${ARGS[0]:-}" == "-a" ]]; then
  pass "pins the installed bundle with -a, never a bare URL open"
else
  fail "first arg must be -a (pin by path), got: ${ARGS[0]:-<none>}"
fi

# 2. The pinned application is exactly the installed path handed in.
if [[ "${ARGS[1]:-}" == "/Applications/Overture.app" ]]; then
  pass "targets the installed /Applications bundle explicitly"
else
  fail "second arg must be the installed app path, got: ${ARGS[1]:-<none>}"
fi

# 3. It still surfaces the window via the overture://show deep link (delivered to the pinned bundle).
if [[ "${ARGS[2]:-}" == "overture://show" ]]; then
  pass "still delivers overture://show so the window surfaces"
else
  fail "third arg must be overture://show, got: ${ARGS[2]:-<none>}"
fi

# 4. A path with spaces survives (each arg is a whole line, never word-split).
ARGS2=()
while IFS= read -r a; do ARGS2+=("$a"); done < <(overture_launch_open_args "/Applications/My Apps/Overture.app")
if [[ "${ARGS2[1]:-}" == "/Applications/My Apps/Overture.app" ]]; then
  pass "a path with spaces stays a single argument"
else
  fail "a spaced path must stay one arg, got: ${ARGS2[1]:-<none>}"
fi

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "launch-surface.test.sh: all assertions passed"
  exit 0
else
  echo "launch-surface.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
