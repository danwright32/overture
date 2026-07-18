#!/usr/bin/env bash
set -uo pipefail

# Pure-function coverage for check-detached-runner-scope.sh's detached_runner_scope_violations (#1102).
# The real check scans every mac/scripts/*.sh file for a detached "$CLAUDE" -p call that bypasses the
# fail-closed *_claude_scope functions in mac/scripts/lib/claude-run-scope.sh (#1026/#1097); this
# fixture drives the same detector against throwaway shell-like text so it runs anywhere including CI,
# and proves the guard both PASSES the consolidated fold-through shape and FAILS the reintroduced bare
# --allowedTools it exists to catch.
#
# The load-bearing case is `red`: a runner that hardcodes --allowedTools at its own "$CLAUDE" -p call
# site is the exact #1026 shape (full shell and Edit access silently inherited from the auto permission
# mode). If the detector stops flagging that, this fixture goes red, which is the mutation this guard
# must survive.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./check-detached-runner-scope.sh
source "${SCRIPT_DIR}/check-detached-runner-scope.sh"
# check-detached-runner-scope.sh's own `set -euo pipefail` is now active. Turn errexit off so one
# failing assertion doesn't abort the rest of the run.
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

# Runs detached_runner_scope_violations, capturing its printed lines in OUT and their count in COUNT.
run_detect() {
  OUT="$(detached_runner_scope_violations "$1")"
  if [[ -z "${OUT}" ]]; then
    COUNT=0
  else
    COUNT="$(printf '%s\n' "${OUT}" | grep -c '^')"
  fi
}

# GREEN: the consolidated shape every real runner uses today. It sources the shared lib, builds its
# claude flags from a *_claude_scope function, and carries no literal --allowedTools anywhere.
GREEN='
#!/usr/bin/env bash
set -eu
. "$(dirname "$0")/lib/claude-run-scope.sh"

FOO_SCOPE="$(foo_claude_scope)" || { echo "foo: aborting, unsafe tool scope" >&2; exit 1; }

# shellcheck disable=SC2086
"$CLAUDE" -p "$PROMPT" \
  --model "$OVERTURE_MODEL_FOO" \
  $FOO_SCOPE &
CLAUDE_PID=$!
wait "$CLAUDE_PID"
'
run_detect "${GREEN}"
assert_eq "green: the consolidated fold-through shape has no violations" "0" "${COUNT}"

# RED (the mutation this guard exists to catch): a fourth runner reintroduces the #1026 hole by
# hardcoding --allowedTools directly at its own claude -p call site instead of folding through a scope
# function. Now the run silently inherits the auto permission mode again.
RED='
#!/usr/bin/env bash
set -eu

# shellcheck disable=SC2086
"$CLAUDE" -p "$PROMPT" \
  --model "$OVERTURE_MODEL_FOO" \
  --allowedTools "Read,Write,WebFetch" &
CLAUDE_PID=$!
wait "$CLAUDE_PID"
'
run_detect "${RED}"
if [[ "${COUNT}" -ge 1 ]]; then
  echo "ok - red: at least one violation detected for the bare --allowedTools call site"
else
  echo "FAIL - red: expected at least one violation, got none"
  FAILURES=$((FAILURES + 1))
fi
assert_contains "red: names the bare --allowedTools hole" "${OUT}" "hardcodes a literal --allowedTools"

# RED variant: a runner that invokes claude -p but never calls ANY *_claude_scope function at all (no
# --allowedTools literal either, just an unscoped call) must also be caught: an empty or missing scope
# is just as unsafe as a hardcoded one, since nothing then adds --permission-mode manual.
RED_NO_SCOPE='
#!/usr/bin/env bash
set -eu

"$CLAUDE" -p "$PROMPT" \
  --model "$OVERTURE_MODEL_FOO" &
CLAUDE_PID=$!
wait "$CLAUDE_PID"
'
run_detect "${RED_NO_SCOPE}"
if [[ "${COUNT}" -ge 1 ]]; then
  echo "ok - red (no scope): a claude -p call with no scope fold at all is flagged"
else
  echo "FAIL - red (no scope): expected at least one violation, got none"
  FAILURES=$((FAILURES + 1))
fi
assert_contains "red (no scope): names the missing scope fold" "${OUT}" "without calling any *_claude_scope function"

# Comments that NAME --allowedTools to explain the historical bug (every real runner's header does this)
# must not count as a live call site. A file with only such comments and no actual "$CLAUDE" -p call is
# not a detached runner at all.
COMMENTED_ONLY='
#!/usr/bin/env bash
# Before #1026 this runner passed only --allowedTools "Read,Write,WebFetch" with no permission mode.
# shellcheck disable=SC2086  # $FOO_SCOPE MUST word-split into --allowedTools <list> --permission-mode <mode>
echo "not actually a runner"
'
run_detect "${COMMENTED_ONLY}"
assert_eq "commented-only: no claude -p call at all means no violation, even though --allowedTools is named in a comment" "0" "${COUNT}"

# A file that mentions --allowedTools in a comment ABOVE a real, correctly-scoped claude -p call must
# still pass: the comment must not leak into the code scan.
GREEN_WITH_HISTORY_COMMENT='
#!/usr/bin/env bash
. "$(dirname "$0")/lib/claude-run-scope.sh"
# Before #1026 this runner passed only --allowedTools "Read,Write" with no permission mode; it now folds
# through bar_claude_scope instead.
BAR_SCOPE="$(bar_claude_scope)" || exit 1
# shellcheck disable=SC2086
"$CLAUDE" -p "$PROMPT" \
  --model "$OVERTURE_MODEL_BAR" \
  $BAR_SCOPE &
wait
'
run_detect "${GREEN_WITH_HISTORY_COMMENT}"
assert_eq "green with a history comment: the comment naming --allowedTools does not trip the guard" "0" "${COUNT}"

# A file that never launches a detached claude run at all (lib/claude-run-scope.sh itself: it only
# DEFINES the *_claude_scope functions, never calls "$CLAUDE" -p) must never be flagged.
LIB_DEFINITION_ONLY='
#!/usr/bin/env bash
claude_run_scope() {
  local allow="$1" mode="$2"
  printf "%s" "--allowedTools ${allow} --permission-mode ${mode}"
}
foo_claude_scope() {
  claude_run_scope "Read,Write" "manual"
}
'
run_detect "${LIB_DEFINITION_ONLY}"
assert_eq "lib definition only: a file that defines scope functions but never calls claude -p is not scanned" "0" "${COUNT}"

echo
echo "--- integration: the real script invoked against temporary fixture files ---"

# Beyond the pure-function checks above, prove the wired-up main() (file discovery, exit codes) behaves
# the same way when handed real files on disk, the way scripts/test-all.sh will actually invoke it.
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/check-detached-runner-scope-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

GOOD_FIXTURE="${TMP_DIR}/good-runner.sh"
printf '%s' "${GREEN}" > "${GOOD_FIXTURE}"

BAD_FIXTURE="${TMP_DIR}/bad-runner.sh"
printf '%s' "${RED}" > "${BAD_FIXTURE}"

"${SCRIPT_DIR}/check-detached-runner-scope.sh" "${GOOD_FIXTURE}" >/dev/null 2>&1
GOOD_STATUS=$?
assert_eq "integration: the real script exits 0 against a temporary fixture that folds through a scope function" "0" "${GOOD_STATUS}"

"${SCRIPT_DIR}/check-detached-runner-scope.sh" "${BAD_FIXTURE}" >/dev/null 2>&1
BAD_STATUS=$?
if [[ "${BAD_STATUS}" -ne 0 ]]; then
  echo "ok - integration: the real script exits non-zero against a temporary fixture with a bare --allowedTools call site"
else
  echo "FAIL - integration: expected a non-zero exit against the bad fixture, got 0"
  FAILURES=$((FAILURES + 1))
fi

echo
echo "--- the three real runners on main must pass with zero false positives ---"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REAL_RUNNERS=(
  "${REPO_ROOT}/mac/scripts/scout-extract-run.sh"
  "${REPO_ROOT}/mac/scripts/prep-run.sh"
  "${REPO_ROOT}/mac/scripts/reply-classify-run.sh"
)
"${SCRIPT_DIR}/check-detached-runner-scope.sh" "${REAL_RUNNERS[@]}"
REAL_STATUS=$?
assert_eq "the three real, already-fixed runners produce zero false positives" "0" "${REAL_STATUS}"

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "check-detached-runner-scope.test.sh: all assertions passed"
  exit 0
else
  echo "check-detached-runner-scope.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
