#!/usr/bin/env bash
set -uo pipefail

# Coverage for the shared assertion vocabulary (#2501), plus the guard that every fixture in the repo
# actually sources it.
#
# This is the one fixture that deliberately does NOT use the shared helpers to make its own checks:
# a helper checked with itself can only report that it agrees with itself, so each case below is
# spelled out in plain bash. Every helper is driven through both verdicts, because a helper that can
# only say "ok" is exactly the failure mode this whole issue is about.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIB="${SCRIPT_DIR}/shell-assertions.sh"

FAILURES=0

check() {
  local desc="$1" condition="$2"
  if [[ "${condition}" == "true" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    FAILURES=$((FAILURES + 1))
  fi
}

# Runs one helper call in a subshell that has sourced the library, and prints its output followed by
# a line giving the FAILURES the call left behind, so both halves of a verdict can be read at once.
run_helper() {
  (
    # shellcheck source=./shell-assertions.sh
    source "${LIB}"
    FAILURES=0
    "$@"
    echo "FAILURES=${FAILURES}"
  )
}

expect_pass() {
  local desc="$1"; shift
  local out; out="$(run_helper "$@")"
  local ok="false"
  [[ "${out}" == *"ok - "* && "${out}" == *"FAILURES=0"* ]] && ok="true"
  check "${desc}" "${ok}"
  [[ "${ok}" == "true" ]] || echo "  got: ${out}"
}

expect_fail() {
  local desc="$1"; shift
  local out; out="$(run_helper "$@")"
  local ok="false"
  [[ "${out}" == *"FAIL - "* && "${out}" == *"FAILURES=1"* ]] && ok="true"
  check "${desc}" "${ok}"
  [[ "${ok}" == "true" ]] || echo "  got: ${out}"
}

expect_pass "pass says ok and counts nothing" pass "a description"
expect_fail "fail says FAIL and counts one" fail "a description" "some detail"

expect_pass "assert_contains passes when the haystack holds the needle" \
  assert_contains "desc" "a full haystack" "haystack"
expect_fail "assert_contains fails when it does not" \
  assert_contains "desc" "a full haystack" "needle"

expect_pass "assert_not_contains passes when the needle is absent" \
  assert_not_contains "desc" "a full haystack" "needle"
expect_fail "assert_not_contains fails when the needle is present" \
  assert_not_contains "desc" "a full haystack" "haystack"

expect_pass "assert_equals passes on equal values" assert_equals "desc" "same" "same"
expect_fail "assert_equals fails on different values" assert_equals "desc" "one" "other"

expect_pass "assert_eq passes on equal values" assert_eq "desc" "same" "same"
expect_fail "assert_eq fails on different values" assert_eq "desc" "one" "other"

expect_pass "assert_empty passes on an empty value" assert_empty "desc" ""
expect_fail "assert_empty fails on a non-empty value" assert_empty "desc" "something"

# The counter has to survive `set -u` in a fixture that never initialised FAILURES, or sourcing this
# library would turn a clean fixture into an unbound-variable crash on its first failing assertion.
UNSET_OUT="$(
  set -u
  # shellcheck source=./shell-assertions.sh
  source "${LIB}"
  unset FAILURES
  fail "a failure with no counter set up" 2>&1
  echo "FAILURES=${FAILURES}"
)"
UNSET_OK="false"
[[ "${UNSET_OUT}" == *"FAILURES=1"* ]] && UNSET_OK="true"
check "a failure with FAILURES never set starts the count at one" "${UNSET_OK}"
[[ "${UNSET_OK}" == "true" ]] || echo "  got: ${UNSET_OUT}"

# A fixture's own definition must still win, because the argument orders were never unanimous: two
# fixtures read assert_contains as (desc, needle, haystack), and sourcing a shared file must not
# quietly reverse what their existing checks mean.
OVERRIDE_OUT="$(
  # shellcheck source=./shell-assertions.sh
  source "${LIB}"
  FAILURES=0
  assert_contains() { echo "the fixture's own"; }
  assert_contains "desc" "a" "b"
  echo "FAILURES=${FAILURES}"
)"
OVERRIDE_OK="false"
[[ "${OVERRIDE_OUT}" == *"the fixture's own"* && "${OVERRIDE_OUT}" == *"FAILURES=0"* ]] && OVERRIDE_OK="true"
check "a fixture's own definition replaces the shared one" "${OVERRIDE_OK}"
[[ "${OVERRIDE_OK}" == "true" ]] || echo "  got: ${OVERRIDE_OUT}"

# The wiring, derived from the tree rather than from a list somebody maintained: a registry only ever
# checks what it remembers, and the fixture that forgets to source this is exactly the one missing
# from it (L96). Comments are stripped before matching, so a file that only MENTIONS the library in a
# comment does not read as one that sources it (L103).
# Matched in bash against the whole stripped file rather than through `sed | grep -q`: grep -q stops
# reading at its first match, sed takes SIGPIPE for it, and under `set -o pipefail` that reads as a
# failed search. It only bites on files big enough for sed to still be writing, so the two largest
# fixtures in the repo reported as unwired while the 46 smaller ones passed.
UNSOURCED=()
while IFS= read -r -d '' fixture; do
  [[ "${fixture}" == "scripts/lib/shell-assertions.test.sh" ]] && continue
  STRIPPED="$(sed 's/#.*//' "${REPO_ROOT}/${fixture}")"
  if [[ "${STRIPPED}" != *"shell-assertions.sh"* ]]; then
    UNSOURCED+=("${fixture}")
  fi
done < <(cd "${REPO_ROOT}" && find scripts mac/scripts -name '*.test.sh' -print0 | sort -z)

if [[ "${#UNSOURCED[@]}" -eq 0 ]]; then
  echo "ok - every fixture sources the shared assertion vocabulary"
else
  echo "FAIL - ${#UNSOURCED[@]} fixture(s) do not source scripts/lib/shell-assertions.sh"
  printf '  %s\n' "${UNSOURCED[@]}"
  FAILURES=$((FAILURES + 1))
fi

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All shell-assertions.sh fixtures passed."
  exit 0
else
  echo "${FAILURES} shell-assertions.sh fixture(s) failed."
  exit 1
fi
