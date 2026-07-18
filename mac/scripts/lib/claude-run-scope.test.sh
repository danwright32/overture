#!/usr/bin/env bash
set -uo pipefail

# #1097: the shared guard that turns a detached claude run's --allowedTools from a mere pre-approval into
# a HARD boundary, exercised for all three detached runners at once.
#
# The bug is the same one #1026 caught for scout, and it is invisible from the allowlist alone. A detached
# `claude -p` inherits the ~/.claude settings an interactive session has, where permissions.defaultMode is
# "auto". Under auto, --allowedTools PRE-APPROVES the tools it names but does NOT restrict to them: every
# OTHER tool (Bash, Edit, Skill, WebSearch, anything the environment exposes) is auto-approved too. So a
# prep or reply-classify run that passed only --allowedTools had full shell and Edit access despite a
# comment claiming otherwise. --permission-mode manual OVERRIDES the inherited auto: anything outside the
# allowlist needs an approval a detached run can never give, so it is denied.
#
# scout-extract already folds through this guard (#1026); #1097 routes prep and reply-classify through the
# SAME one rather than copying it, so the fail-closed posture cannot be right in one runner and a drifted
# near-copy in another (the exact defect #1073/#982 warn about). This fixture asserts the SECURITY
# INVARIANT for the generic guard and both new scopes: the emitted scope pre-approves exactly the tools a
# run needs, carries a mode that auto-approves nothing else, and REFUSES to run (fail loud, emit nothing)
# the moment either drifts unsafe.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

pass() { echo "ok - $1"; }
fail() {
  echo "FAIL - $1"
  if [[ $# -gt 1 ]]; then echo "  $2"; fi
  FAILURES=$((FAILURES + 1))
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then pass "${desc}"; else
    fail "${desc}" "expected to contain: ${needle} / in: ${haystack}"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then pass "${desc}"; else
    fail "${desc}" "must NOT contain: ${needle} / in: ${haystack}"
  fi
}

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/claude-run-scope.sh"

# --- the generic guard, directly -----------------------------------------------------------------------

# Happy path: it emits both flags, in the shape the runners splice onto the claude command line.
generic="$(claude_run_scope "Read,Write" "manual" "Bash Edit" "unit")"
generic_status=$?
[[ "${generic_status}" -eq 0 ]] || fail "the generic guard emits cleanly on a safe scope" "returned ${generic_status}"
assert_contains "the generic guard pre-approves exactly the tools it is given" "${generic}" "--allowedTools Read,Write"
assert_contains "the generic guard carries the permission mode it is given" "${generic}" "--permission-mode manual"

# Failure path: an empty or auto-approving mode is the whole bug (an allowlist with nothing closing the
# door behind it), so the guard must refuse and emit nothing.
for dangerous in auto bypassPermissions dontAsk acceptEdits ""; do
  out="$(claude_run_scope "Read,Write" "${dangerous}" "" "unit" 2>/dev/null)"
  st=$?
  label="${dangerous:-<empty>}"
  if [[ "${st}" -ne 0 && -z "${out}" ]]; then
    pass "the generic guard refuses the auto-approving mode '${label}' and emits nothing"
  else
    fail "the generic guard must refuse the auto-approving mode '${label}'" "status ${st}, emitted: ${out}"
  fi
done

# The two fail-closed modes ARE accepted, so the guard is a real distinction and not a blanket refusal
# that would pass while forbidding everything (green means nothing until you have seen it go red).
for safe in manual plan; do
  if claude_run_scope "Read,Write" "${safe}" "" "unit" >/dev/null 2>&1; then
    pass "the generic guard accepts the fail-closed mode '${safe}'"
  else
    fail "the generic guard must accept the fail-closed mode '${safe}'"
  fi
done

# Failure path: a forbidden tool that has crept into the allowlist must be refused, loudly. Matched with
# commas around both sides so "WebFetch" can never match "WebSearch" nor "Read" a substring of another.
out="$(claude_run_scope "Read,Write,Edit" "manual" "Bash Edit" "unit" 2>/dev/null)"
st=$?
if [[ "${st}" -ne 0 && -z "${out}" ]]; then
  pass "the generic guard refuses an allowlist that smuggles in a forbidden tool"
else
  fail "the generic guard must refuse a forbidden tool in the allowlist" "status ${st}, emitted: ${out}"
fi
# ...but a forbidden name that is only a SUBSTRING of an allowed tool must NOT trip the guard.
if claude_run_scope "Read,Write,WebFetch" "manual" "WebSearch" "unit" >/dev/null 2>&1; then
  pass "the generic guard does not confuse WebFetch in the allowlist with a forbidden WebSearch"
else
  fail "the generic guard wrongly refused WebFetch when only WebSearch is forbidden"
fi

# --- prep's scope: the run that writes emails reaching strangers in Dan's voice ------------------------
#
# Prep DELIBERATELY needs Bash and Skill (it drives research and invokes the dan-wright-brand-voice
# skill), so this is not a copy of the scout posture. What must stay true is that the mode closes the door
# on everything ELSE (Edit above all: the 2026-07-17 scout run made 14 Edit calls it was never granted).
prep="$(prep_claude_scope)"
prep_status=$?
[[ "${prep_status}" -eq 0 ]] || fail "the prep scope emits cleanly" "returned ${prep_status}"
assert_contains "prep pre-approves the six tools its job needs" "${prep}" "--allowedTools Read,Write,WebSearch,WebFetch,Bash,Skill"
assert_contains "prep carries the fail-closed permission mode" "${prep}" "--permission-mode manual"
assert_contains "prep can invoke the brand-voice skill its prompt names" "${prep}" "Skill"
# Edit is the tool a run must never regain here; the mode denies it, and it must not sit in the allowlist.
assert_not_contains "prep does not pre-approve Edit" "${prep}" "Edit"
# And if a later edit adds Edit to the allowlist, the guard must refuse rather than emit it.
if PREP_ALLOWED_TOOLS="Read,Write,Edit" prep_claude_scope >/dev/null 2>&1; then
  fail "the prep scope must refuse an allowlist that adds Edit"
else
  pass "the prep scope refuses an allowlist that adds Edit"
fi
# And if the mode is ever cleared back to the inherited auto, prep must refuse too.
if PREP_PERMISSION_MODE="" prep_claude_scope >/dev/null 2>&1; then
  fail "the prep scope must refuse an empty permission mode (it would inherit auto)"
else
  pass "the prep scope refuses an empty permission mode"
fi

# --- reply-classify's scope: the tightest of the three ------------------------------------------------
#
# It reads the work-list and the voice guidance, drafts a reply, and writes results. It needs Read, Write
# and Skill (to invoke the brand-voice skill), and nothing else: no Bash, no Edit, no web access at all.
reply="$(reply_classify_claude_scope)"
reply_status=$?
[[ "${reply_status}" -eq 0 ]] || fail "the reply-classify scope emits cleanly" "returned ${reply_status}"
assert_contains "reply-classify pre-approves exactly Read, Write and Skill" "${reply}" "--allowedTools Read,Write,Skill"
assert_contains "reply-classify carries the fail-closed permission mode" "${reply}" "--permission-mode manual"
assert_contains "reply-classify can invoke the brand-voice skill its prompt names" "${reply}" "Skill"
for never in Bash Edit WebFetch WebSearch; do
  assert_not_contains "reply-classify does not pre-approve ${never}" "${reply}" "${never}"
  if REPLY_CLASSIFY_ALLOWED_TOOLS="Read,Write,Skill,${never}" reply_classify_claude_scope >/dev/null 2>&1; then
    fail "the reply-classify scope must refuse an allowlist that adds ${never}"
  else
    pass "the reply-classify scope refuses an allowlist that adds ${never}"
  fi
done

# --- both runners fold through the scope; neither hardcodes the old, unrestricted flag ----------------
#
# The load-bearing wiring: each runner must SOURCE the shared lib, build its claude flags from its scope
# function, and carry NO bare --allowedTools literal on a call site (which would run that path on the old
# --allowedTools-only posture with no permission mode, the very hole #1097 closes). Comment lines are
# stripped first so a header recounting the old flag as history is not mistaken for a live call site.
assert_runner_folds_through_scope() {
  local script="$1" scope_fn="$2"
  local path="${SCRIPT_DIR}/../${script}"
  local body code
  body="$(cat "${path}")"
  code="$(printf '%s\n' "${body}" | grep -v '^[[:space:]]*#')"

  assert_contains "${script} sources the shared tool scope" "${body}" "lib/claude-run-scope.sh"
  assert_contains "${script} builds its claude flags from ${scope_fn}" "${body}" "${scope_fn}"

  if printf '%s' "${code}" | grep -q -- '--allowedTools'; then
    fail "${script} still hardcodes --allowedTools on a call site" \
         "every claude invocation must fold through ${scope_fn}, or a call site keeps the unrestricted flag"
  else
    pass "${script} hardcodes no --allowedTools flag on any call site"
  fi

  # Each of these runners launches claude exactly once; that invocation must carry the resolved scope.
  local claude_calls scope_uses
  claude_calls="$(printf '%s\n' "${body}" | grep -c '"\$CLAUDE" -p')"
  scope_uses="$(printf '%s\n' "${code}" | grep -c "${scope_fn}\|_SCOPE")"
  if [[ "${claude_calls}" -ge 1 && "${scope_uses}" -ge 1 ]]; then
    pass "${script}: its claude invocation (${claude_calls}) carries the scope (${scope_uses} references)"
  else
    fail "${script}: the claude invocation must carry the scope" "claude calls: ${claude_calls}, scope refs: ${scope_uses}"
  fi
}

assert_runner_folds_through_scope "prep-run.sh" "prep_claude_scope"
assert_runner_folds_through_scope "reply-classify-run.sh" "reply_classify_claude_scope"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all claude-run-scope.sh checks passed"
