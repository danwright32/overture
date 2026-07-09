#!/usr/bin/env bash
set -uo pipefail

# Coverage for run-shell-fixtures.sh's run_shell_fixtures (#698): runs every given fixture script,
# never stops at the first failure (so one broken fixture doesn't hide another), and reports
# overall pass/fail via its own return code. Uses real, disposable throwaway scripts in a temp dir
# rather than the repo's actual *.test.sh files, so this test doesn't depend on (or duplicate) what
# those fixtures individually assert.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./run-shell-fixtures.sh
source "${SCRIPT_DIR}/run-shell-fixtures.sh"
set +e

FAILURES=0

assert_equals() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PASSING="${TMP_DIR}/passing.test.sh"
printf '#!/usr/bin/env bash\necho ok\nexit 0\n' > "${PASSING}"
chmod +x "${PASSING}"

ALSO_PASSING="${TMP_DIR}/also-passing.test.sh"
printf '#!/usr/bin/env bash\necho ok\nexit 0\n' > "${ALSO_PASSING}"
chmod +x "${ALSO_PASSING}"

FAILING="${TMP_DIR}/failing.test.sh"
printf '#!/usr/bin/env bash\necho boom\nexit 1\n' > "${FAILING}"
chmod +x "${FAILING}"

run_shell_fixtures "${PASSING}" "${ALSO_PASSING}" >/dev/null
assert_equals "all-passing fixtures return success" "0" "$?"

run_shell_fixtures "${PASSING}" "${FAILING}" >/dev/null
assert_equals "one failing fixture makes the overall run fail" "1" "$?"

RAN_BOTH_OUTPUT="$(run_shell_fixtures "${FAILING}" "${ALSO_PASSING}" 2>&1)"
DID_RUN_LATER_FIXTURE="false"
[[ "${RAN_BOTH_OUTPUT}" == *"also-passing.test.sh"* ]] && DID_RUN_LATER_FIXTURE="true"
assert_equals "a failure earlier in the list doesn't stop later fixtures from running" \
  "true" "${DID_RUN_LATER_FIXTURE}"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All run-shell-fixtures.sh fixtures passed."
  exit 0
else
  echo "${FAILURES} run-shell-fixtures.sh fixture(s) failed."
  exit 1
fi
