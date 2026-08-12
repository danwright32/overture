#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/shell-assertions.sh"

# #2497 put the four-item completeness enumeration into AGENTS.md, and nothing enforced it: no script
# in this repo read a PR body at all. A rule that lives only in a prompt is a hope (L27), which is the
# same defect one level up from the two the enumeration exists to catch (#2490, #2495).
#
# Drives the decision function directly against bodies that answer all, some and none of it, and then
# drives the refusal end to end, because a decision function nothing calls guards nothing (L3).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${SCRIPT_DIR}/pr-completeness-guard.sh"
FAILURES=0

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected to contain: ${needle}"
    echo "  in: ${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_empty() {
  local desc="$1" actual="$2"
  if [[ -z "${actual}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected nothing, got: ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_status() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "ok - ${desc}"
  else
    echo "FAIL - ${desc} (expected exit ${expected}, got ${actual})"
    FAILURES=$((FAILURES + 1))
  fi
}

# shellcheck source=/dev/null
source "${GUARD}"

COMPLETE_BODY='## The four items
1. Writers: no new stored values.
2. Readers: the rule is read by every author opening a PR here.
3. Siblings: swept the other adapters, none affected.
4. Guards seen to fail: broke the parser, saw "expected 3 got 0", reverted.'

assert_empty "a body answering all four is accepted" \
  "$(pr_completeness_missing "${COMPLETE_BODY}")"

# The failure that actually happened. #2453 named an activating issue for two of three unwritten
# cases: a body can look thorough and still be missing exactly one item.
ONE_MISSING="$(pr_completeness_missing 'Writers listed. Readers listed. Guards were seen to fail with the exact text.')"
assert_contains "the one missing item is named" "${ONE_MISSING}" "siblings"
assert_status "and only that one" "1" "$(printf '%s\n' "${ONE_MISSING}" | grep -c .)"

ALL_MISSING="$(pr_completeness_missing 'Fixes the thing. Tests pass.')"
assert_status "a body answering none reports all four" "4" "$(printf '%s\n' "${ALL_MISSING}" | grep -c .)"

# An empty body has answered nothing. If this were waved through, "write no body" would be the way
# around the guard, which is the hole rather than the exemption.
assert_status "an empty body reports all four rather than passing" "4" \
  "$(pr_completeness_missing '' | grep -c .)"

# Answering the question is the bar, not spelling it a particular way.
assert_empty "headings in other cases and plurals still count" \
  "$(pr_completeness_missing '## WRITERS
## Readers
## Siblings swept
## Every guard was SEEN to fail')"

# End to end: the refusal must exit non-zero and say what is missing, or the merge scripts that call
# it would carry on regardless and this would be decoration.
OUT="$( ( require_pr_completeness 4242 'Writers and readers are listed.' ) 2>&1 )"
STATUS=$?
assert_status "refuses with a non-zero exit" "1" "${STATUS}"
assert_contains "names the PR" "${OUT}" "PR #4242"
assert_contains "names an unanswered item" "${OUT}" "siblings"
assert_contains "says passing is not evidence of completeness" "${OUT}" "not evidence"
assert_contains "names the defects it exists to catch" "${OUT}" "#2490"
assert_contains "says how to fix it" "${OUT}" "gh pr edit 4242"

OUT_OK="$( ( require_pr_completeness 4243 "${COMPLETE_BODY}" ) 2>&1 )"
assert_status "a complete body is not refused" "0" "$?"
assert_empty "and says nothing" "${OUT_OK}"

# WIRING. Everything above proves the decision function decides correctly, and would keep passing if
# no merge script ever called it, which is precisely how #2497 shipped a rule nothing enforced. Both
# merge paths have to fold through this, or a PR is waved through by picking the other script.
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
for script in verify-and-merge-branch.sh merge-when-green.sh; do
  src="$(cat "${REPO_ROOT}/scripts/${script}" 2>/dev/null || echo "")"
  assert_contains "${script} sources the shared guard" "${src}" "lib/pr-completeness-guard.sh"
  assert_contains "${script} actually calls it" "${src}" "require_pr_completeness"
done

# It has to run BEFORE the expensive part, or a missing body costs two minutes of exclusive test lock
# to discover. Checked by position, since "it is called somewhere" would pass with it at the end.
VAM="$(cat "${REPO_ROOT}/scripts/verify-and-merge-branch.sh" 2>/dev/null || echo "")"
GUARD_LINE="$(printf '%s\n' "${VAM}" | grep -n 'require_pr_completeness' | head -1 | cut -d: -f1)"
SUITE_LINE="$(printf '%s\n' "${VAM}" | grep -n 'setup_worktree "' | head -1 | cut -d: -f1)"
if [[ -n "${GUARD_LINE}" && -n "${SUITE_LINE}" && "${GUARD_LINE}" -lt "${SUITE_LINE}" ]]; then
  echo "ok - the refusal happens before the worktree and the suite"
else
  echo "FAIL - the refusal must come before setup_worktree (guard at ${GUARD_LINE:-none}, worktree at ${SUITE_LINE:-none})"
  FAILURES=$((FAILURES + 1))
fi

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all pr-completeness-guard checks passed"
