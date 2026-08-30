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

# --- assert_pids_gone (#3248) -------------------------------------------------------------------
#
# The one helper here that is about TIME rather than about a value, so it is driven against real
# processes rather than against strings. Every process it is pointed at below is a GRANDCHILD of this
# fixture (started by a `bash -c` that exits immediately), never a child of it, for a reason that
# decides whether these cases measure anything at all: a dead CHILD of this shell stays a zombie until
# something waits on it, and `kill -0` succeeds on a zombie, so a child would read as alive long after
# it had exited and the waiting case below could never pass. An orphan is reaped by launchd instead.

# Waited ON rather than waited OUT: a fixed delay here would be an assertion about how busy this Mac
# is, and it is the slower answer too, since the ordinary case clears on the first look (L290). This
# is the fixture for a helper whose whole subject is that mistake, so it must not make it.
PIDS_GONE_EXITED="$(bash -c 'sleep 0 >/dev/null 2>&1 & echo $!')"
WAITED=0
while kill -0 "${PIDS_GONE_EXITED}" 2>/dev/null && [[ "${WAITED}" -lt 200 ]]; do
  sleep 0.05
  WAITED=$((WAITED + 1))
done
check "the already-gone pid really did go, so the next line is about a dead pid" \
  "$(if kill -0 "${PIDS_GONE_EXITED}" 2>/dev/null; then echo false; else echo true; fi)"
expect_pass "assert_pids_gone passes on a pid that has already gone" \
  assert_pids_gone "the job is gone" "${PIDS_GONE_EXITED}"

# THE case, and the one a single `kill -0` cannot pass: a process still on its way out when the
# assertion is made. #3248 is exactly this, seen live on 2026-08-29 as `still alive: 20800` from a
# fixture that sampled once, on a Mac that was running the Swift suite beside it.
PIDS_GONE_LEAVING="$(bash -c 'sleep 3 >/dev/null 2>&1 & echo $!')"
LEAVING_ALIVE_AT_FIRST="false"
kill -0 "${PIDS_GONE_LEAVING}" 2>/dev/null && LEAVING_ALIVE_AT_FIRST="true"
# Asserted BEFORE the case it sets up, because a process that had already exited would satisfy the
# waiting case just as well as a helper that waits, and the case would pass hardest while measuring
# nothing (L159). Three seconds is chosen so it is still alive after this fixture's own subshell
# setup, not because three is a meaningful duration.
check "the leaving process really is still alive when the assertion is made" "${LEAVING_ALIVE_AT_FIRST}"
LEAVING_STARTED_AT="${SECONDS}"
expect_pass "assert_pids_gone waits out a process that is still on its way out" \
  assert_pids_gone "the job is gone" "${PIDS_GONE_LEAVING}"
LEAVING_TOOK=$(( SECONDS - LEAVING_STARTED_AT ))
LEAVING_WAITED="false"
[[ "${LEAVING_TOOK}" -ge 1 ]] && LEAVING_WAITED="true"
check "and really waited for it rather than finding it already gone" "${LEAVING_WAITED}"

# And it FAILS on one that really stays, rather than hanging: a wait with no deadline cannot fail, it
# can only hang, and a hang is worse than a failure because it is indistinguishable from slowness
# (L110). The deadline is injected rather than waited out, so this case costs a second (L290).
PIDS_GONE_STAYING="$(bash -c 'sleep 45 >/dev/null 2>&1 & echo $!')"
STAYING_STARTED_AT="${SECONDS}"
STAYING_OUT="$(SHELL_ASSERTION_PIDS_GONE_DEADLINE_SECONDS=1 run_helper \
  assert_pids_gone "the job is gone" "${PIDS_GONE_STAYING}")"
STAYING_TOOK=$(( SECONDS - STAYING_STARTED_AT ))
STAYING_OK="false"
[[ "${STAYING_OUT}" == *"FAIL - "* && "${STAYING_OUT}" == *"FAILURES=1"* ]] && STAYING_OK="true"
check "assert_pids_gone fails on a process that really stays" "${STAYING_OK}"
[[ "${STAYING_OK}" == "true" ]] || echo "  got: ${STAYING_OUT}"

# Naming the survivor is the whole value of the failure: the pid is the only thing that lets anyone
# ask what it was (L11, L148).
NAMES_OK="false"
[[ "${STAYING_OUT}" == *"${PIDS_GONE_STAYING}"* ]] && NAMES_OK="true"
check "and names the pid that survived, so it can be looked up" "${NAMES_OK}"
[[ "${NAMES_OK}" == "true" ]] || echo "  got: ${STAYING_OUT}"

BOUNDED_OK="false"
[[ "${STAYING_TOOK}" -lt 20 ]] && BOUNDED_OK="true"
check "and returns on its deadline rather than waiting the process out" "${BOUNDED_OK}"
[[ "${BOUNDED_OK}" == "true" ]] || echo "  took ${STAYING_TOOK}s against a 45 second process"

kill "${PIDS_GONE_STAYING}" 2>/dev/null || true

# Nothing to wait for is its own outcome and must never read as the cleanest possible pass (L98).
# Every caller collects the pids first and has already asserted it found some, so an empty list here
# means that collection came back empty and the assertion measured nothing.
expect_fail "assert_pids_gone given no pids at all reports measuring nothing" \
  assert_pids_gone "the job is gone"

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

# --- the scoped scratch directory (#3249) --------------------------------------------------------
#
# The rule that fails a fixture for leaving files behind lives in the RUNNER, which gives each fixture
# its own temp directory and inspects it afterwards. Run a fixture the way a person actually runs one
# while working, `bash scripts/lib/whatever.test.sh`, and none of that applies: the fixture writes into
# the real shared folder, which macOS clears only at boot, and nothing looks. So the protection is
# strongest exactly where it is least needed and absent where the mess accumulates.
#
# Sourcing this library is the one thing every fixture does, so it is where the scoping can be made to
# hold wherever the fixture is invoked from.

# A fresh scratch is made when nothing has scoped one already.
SCOPE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/scope-home.XXXXXX")"
SCOPE_OUT="$(TMPDIR="${SCOPE_HOME}" OVERTURE_FIXTURE_TMPDIR_SCOPED="" bash -c '
  source "'"${LIB}"'"
  echo "${TMPDIR}"
')"
SCOPE_OK="false"
[[ "${SCOPE_OUT}" == "${SCOPE_HOME}"/* && -d "${SCOPE_OUT}" ]] && SCOPE_OK="true"
check "sourcing the library points TMPDIR at a fresh directory of its own" "${SCOPE_OK}"
[[ "${SCOPE_OK}" == "true" ]] || echo "  got: ${SCOPE_OUT} (home was ${SCOPE_HOME})"

# THE case, and the one that decides whether any of this contains anything. On macOS `mktemp` ignores
# TMPDIR unless the path is spelled out: measured 2026-08-30, `TMPDIR=$H mktemp -d` lands in the real
# shared folder and so does `TMPDIR=$H mktemp -d -t probe`, while `mktemp -d "$TMPDIR/tpl.XXXXXX"`
# lands in $H. So scoping TMPDIR by itself contains NOTHING, and every fixture using the bare form
# (56 of the 81 here, 75 call sites) writes past both this scoping and the runner's.
HELPER_OUT="$(TMPDIR="${SCOPE_HOME}" OVERTURE_FIXTURE_TMPDIR_SCOPED="" bash -c '
  source "'"${LIB}"'"
  fixture_scratch_dir
')"
HELPER_OK="false"
[[ -n "${HELPER_OUT}" && "${HELPER_OUT}" == "${SCOPE_HOME}"/* && -d "${HELPER_OUT}" ]] && HELPER_OK="true"
check "fixture_scratch_dir makes its directory INSIDE the scope, not in the shared folder" "${HELPER_OK}"
[[ "${HELPER_OK}" == "true" ]] || echo "  got: ${HELPER_OUT} (scope was under ${SCOPE_HOME})"

# The control for the line above. Without it, "the helper landed inside the scope" is satisfied by a
# machine where the bare form would have landed there too, and the case would prove nothing about the
# helper (L159). This is the measurement, made by the test rather than quoted from a comment.
BARE_OUT="$(TMPDIR="${SCOPE_HOME}" bash -c 'mktemp -d')"
BARE_ESCAPED="false"
[[ "${BARE_OUT}" != "${SCOPE_HOME}"/* ]] && BARE_ESCAPED="true"
check "and a bare mktemp -d really does escape it, which is why the helper exists" "${BARE_ESCAPED}"
[[ "${BARE_ESCAPED}" == "true" ]] || echo "  bare mktemp landed at ${BARE_OUT}, inside the scope, so the helper is not needed here"
rm -rf "${BARE_OUT}"

# The runner keeps its own scoping, untouched. Nesting one inside it would put every fixture's real
# leak one level below where `fixture_left_temp_files` looks, so the check that already works would
# start reporting one tidy directory and seeing nothing inside it (L98).
RUNNER_HOME="$(mktemp -d "${TMPDIR:-/tmp}/runner-home.XXXXXX")"
RUNNER_OUT="$(TMPDIR="${RUNNER_HOME}" OVERTURE_FIXTURE_TMPDIR_SCOPED=1 bash -c '
  source "'"${LIB}"'"
  echo "${TMPDIR}"
')"
RUNNER_OK="false"
[[ "${RUNNER_OUT}" == "${RUNNER_HOME}" ]] && RUNNER_OK="true"
check "a directory the runner already scoped is left exactly as it was" "${RUNNER_OK}"
[[ "${RUNNER_OK}" == "true" ]] || echo "  got: ${RUNNER_OUT} (runner gave ${RUNNER_HOME})"

# And under the runner the helper's directory lands where the runner LOOKS, which is the half that
# gives the existing leak check its sight back.
RUNNER_HELPER="$(TMPDIR="${RUNNER_HOME}" OVERTURE_FIXTURE_TMPDIR_SCOPED=1 bash -c '
  source "'"${LIB}"'"
  fixture_scratch_dir
')"
RUNNER_HELPER_OK="false"
[[ "${RUNNER_HELPER}" == "${RUNNER_HOME}"/* ]] && RUNNER_HELPER_OK="true"
check "and a scratch made under the runner lands where its leak check looks" "${RUNNER_HELPER_OK}"
[[ "${RUNNER_HELPER_OK}" == "true" ]] || echo "  got: ${RUNNER_HELPER}"

# Cleaning happens on SOURCE rather than on exit, and that is the load-bearing choice. A shell keeps one
# EXIT trap, 59 of this repo's 81 fixtures install their own AFTER sourcing this file, and the second one
# silently wins, so a cleanup hung on a trap here would be replaced in three quarters of the cases and
# would look like it was working the whole time.
SWEEP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/sweep-home.XXXXXX")"
mkdir -p "${SWEEP_HOME}/overture-fixture-999999-deadpid"
touch "${SWEEP_HOME}/overture-fixture-999999-deadpid/left-behind"
mkdir -p "${SWEEP_HOME}/overture-fixture-$$-mine"
touch "${SWEEP_HOME}/not-ours"
TMPDIR="${SWEEP_HOME}" OVERTURE_FIXTURE_TMPDIR_SCOPED="" bash -c 'source "'"${LIB}"'"' >/dev/null 2>&1
SWEPT_OK="false"
[[ ! -d "${SWEEP_HOME}/overture-fixture-999999-deadpid" ]] && SWEPT_OK="true"
check "sourcing it sweeps a scratch left by a run that has since ended" "${SWEPT_OK}"

# Both halves, because a sweep that removes everything is not a sweep, it is a different way of losing
# work: another fixture running right now owns its scratch and must keep it (L104).
KEPT_OK="false"
[[ -d "${SWEEP_HOME}/overture-fixture-$$-mine" && -f "${SWEEP_HOME}/not-ours" ]] && KEPT_OK="true"
check "and keeps one whose run is still going, and anything that is not ours at all" "${KEPT_OK}"
rm -rf "${SCOPE_HOME}" "${RUNNER_HOME}" "${SWEEP_HOME}"

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

# The other half of the wiring, and the one that keeps #3249 fixed. A bare `mktemp` writes past every
# scoping there is on macOS, so a fixture using one is invisible to the runner's leak check whatever
# directory the runner puts it in. Derived from the tree for L96's reason: a hand-kept list of the 56
# fixtures that had this only ever checks what somebody remembered. Heredoc bodies are skipped, because
# those are generated stub scripts that do not source this library and must spell mktemp themselves.
BARE_MKTEMP=()
while IFS= read -r -d '' fixture; do
  [[ "${fixture}" == "scripts/lib/shell-assertions.test.sh" ]] && continue
  IN_HEREDOC=""
  LINE_NO=0
  while IFS= read -r line; do
    LINE_NO=$((LINE_NO + 1))
    if [[ -n "${IN_HEREDOC}" ]]; then
      [[ "$(printf '%s' "${line}" | tr -d '[:space:]')" == "${IN_HEREDOC}" ]] && IN_HEREDOC=""
      continue
    fi
    STRIPPED="${line%%#*}"
    if [[ "${STRIPPED}" == *'$(mktemp)'* || "${STRIPPED}" == *'$(mktemp -d)'* || "${STRIPPED}" == *'mktemp -t '* ]]; then
      BARE_MKTEMP+=("${fixture}:${LINE_NO}")
    fi
    if [[ "${line}" =~ \<\<-?[[:space:]]*\'?([A-Za-z_][A-Za-z0-9_]*)\'?[[:space:]]*$ ]]; then
      IN_HEREDOC="${BASH_REMATCH[1]}"
    fi
  done < "${REPO_ROOT}/${fixture}"
done < <(cd "${REPO_ROOT}" && find scripts mac/scripts -name '*.test.sh' -print0 | sort -z)

if [[ "${#BARE_MKTEMP[@]}" -eq 0 ]]; then
  echo "ok - no fixture uses a bare mktemp, which would write past every scoping there is"
else
  echo "FAIL - ${#BARE_MKTEMP[@]} bare mktemp call(s) in fixtures; use fixture_scratch_dir or fixture_scratch_file"
  printf '  %s\n' "${BARE_MKTEMP[@]}"
  FAILURES=$((FAILURES + 1))
fi

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
