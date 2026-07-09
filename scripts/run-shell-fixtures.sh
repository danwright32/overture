#!/usr/bin/env bash
set -euo pipefail

# Runs every scripts/*.test.sh and mac/scripts/**/*.test.sh fixture in the repo (#698): each covers
# a pure function extracted from its sibling script (classify_stop_reason in merge-when-green.sh,
# stale_debug_test_host_pids in run-tests-locked.sh, etc.). None of them ran automatically before
# this, so a future edit to one of those functions could silently break its fixture until the real
# script misbehaved for real (a bad CI-merge decision, a stale process left running). Wired into
# scripts/test-all.sh so these fixtures ride along with every other local pre-push check.
#
# Usage: scripts/run-shell-fixtures.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Runs each given fixture script in order, letting its own output through, and returns the count of
# fixtures that exited nonzero (so 0 means every fixture passed). Never stops at the first failure,
# so one broken fixture doesn't hide another one behind it. Takes an explicit path list rather than
# globbing itself, so it's testable against a throwaway fixture set without touching the real repo
# scripts.
run_shell_fixtures() {
  local failures=0
  local fixture
  for fixture in "$@"; do
    echo "==> ${fixture}"
    if ! "${fixture}"; then
      echo "FAIL - ${fixture}"
      failures=$((failures + 1))
    fi
    echo
  done
  return "${failures}"
}

main() {
  cd "${REPO_ROOT}"
  local fixtures=()
  while IFS= read -r -d '' f; do
    fixtures+=("${f}")
  done < <(find scripts mac/scripts -name '*.test.sh' -print0 | sort -z)

  if [[ "${#fixtures[@]}" -eq 0 ]]; then
    echo "No *.test.sh fixtures found."
    exit 0
  fi

  echo "Running ${#fixtures[@]} shell fixture(s)..."
  run_shell_fixtures "${fixtures[@]}"
}

# Allow this file to be sourced (e.g. by a test fixture) without running main, so
# run_shell_fixtures can be exercised directly. Mirrors merge-when-green.sh's convention.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
