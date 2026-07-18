#!/usr/bin/env bash
set -uo pipefail

# #1026: the scout-extract run reads UNTRUSTED web content (the pinned org pages, plus each event's
# detail page it follows with WebFetch) and writes the outreach data Dan later pitches from. It must be
# scoped to exactly the three tools its job needs: Read (the local pinned page), WebFetch (the detail
# page), Write (the results file). Nothing else.
#
# The bug this guards against is invisible from the allowlist alone. Before #1026 the runner passed only
# --allowedTools "Read,Write,WebFetch", and its comment claimed "No Bash". That claim was false:
# --allowedTools PRE-APPROVES those three, it does not RESTRICT to them, and the detached run inherits
# ~/.claude settings where permissions.defaultMode is "auto", so every OTHER tool (Bash, Edit, Skill,
# WebSearch) was auto-approved as well. A 2026-07-17 run made 13 Bash and 14 Edit calls with zero
# denials. Adding --permission-mode manual overrides the inherited auto: anything outside the allowlist
# needs an approval a detached run can never give, so it is denied (verified by hand: with manual, a
# Bash or Edit call is blocked while Write still works).
#
# So this fixture asserts the SECURITY INVARIANT, not a literal echo: the scope must pre-approve exactly
# the three read/fetch/write tools, must carry a permission mode that does NOT auto-approve anything
# else, and must REFUSE to run (fail loud) the moment either of those drifts back into an unsafe posture.

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
source "${SCRIPT_DIR}/scout-tools.sh"

# --- the happy path: exactly the three tools, and a mode that closes the door on everything else -------
scope="$(scout_extract_claude_scope)"
scope_status=$?

if [[ "${scope_status}" -ne 0 ]]; then
  fail "the default scout scope must emit cleanly" "returned ${scope_status}"
fi

assert_contains "the scope pre-approves the three tools the job needs" "${scope}" "--allowedTools Read,Write,WebFetch"
assert_contains "the scope carries a permission mode (never relies on the inherited auto)" "${scope}" "--permission-mode manual"

# The whole point: the tools the run must never reach are NOT pre-approved, and (because the mode is not
# auto) not reachable at all. If any of these ever appears in the emitted scope, the run has regained the
# access the comment promised it did not have.
for forbidden in Bash Edit Skill WebSearch; do
  assert_not_contains "the scope never grants ${forbidden}" "${scope}" "${forbidden}"
done

# --- failure path: a mode that auto-approves outside the allowlist must be REFUSED, loudly -------------
#
# This is the load-bearing assertion. --allowedTools alone (an empty / auto mode) is exactly the state
# the 2026-07-17 run was in when it ran shell freely. If a future edit sets the mode back to auto (or any
# of the other approve-everything modes), the scope function must refuse to emit and fail the run rather
# than silently hand the detached run a shell again.
for dangerous in auto bypassPermissions dontAsk acceptEdits ""; do
  out="$(SCOUT_EXTRACT_PERMISSION_MODE="${dangerous}" scout_extract_claude_scope 2>/dev/null)"
  st=$?
  label="${dangerous:-<empty>}"
  if [[ "${st}" -ne 0 ]]; then
    pass "the scope refuses to run under the auto-approving mode '${label}'"
  else
    fail "the scope must refuse the auto-approving mode '${label}'" "it emitted: ${out}"
  fi
  if [[ -z "${out}" ]]; then
    pass "and emits no flags when it refuses '${label}' (a partial scope is worse than none)"
  else
    fail "a refused scope must emit nothing for '${label}'" "it emitted: ${out}"
  fi
done

# The two restrictive modes that DO close the door are accepted, so the guard is a real distinction and
# not a blanket refusal that would pass while forbidding everything (green means nothing until seen red).
for safe in manual plan; do
  if SCOUT_EXTRACT_PERMISSION_MODE="${safe}" scout_extract_claude_scope >/dev/null 2>&1; then
    pass "the scope accepts the fail-closed mode '${safe}'"
  else
    fail "the scope must accept the fail-closed mode '${safe}'"
  fi
done

# --- failure path: a forbidden tool sneaking into the allowlist must be REFUSED, loudly ----------------
for bad_allow in "Read,Write,WebFetch,Bash" "Read,Write,Edit,WebFetch" "Read,Write,WebFetch,Skill"; do
  out="$(SCOUT_EXTRACT_ALLOWED_TOOLS="${bad_allow}" scout_extract_claude_scope 2>/dev/null)"
  st=$?
  if [[ "${st}" -ne 0 && -z "${out}" ]]; then
    pass "the scope refuses an allowlist that smuggles in a forbidden tool: ${bad_allow}"
  else
    fail "the scope must refuse the allowlist '${bad_allow}'" "status ${st}, emitted: ${out}"
  fi
done

# --- both invocation paths fold through the SAME scope (the models.sh lesson) --------------------------
#
# The runner launches claude in two places: one per chunk (run_claude_on_chunk) and a single-process
# fallback on a node-free machine. A restriction that is present in one and missing from the other is the
# same bug wearing a disguise, so assert the script sources this lib, uses the scope, and carries NO bare
# hardcoded allowlist literal that would mean a call site was left behind on the old, unrestricted flag.
runner="${SCRIPT_DIR}/../scout-extract-run.sh"
runner_body="$(cat "${runner}")"

assert_contains "scout-extract-run.sh sources the shared tool scope" "${runner_body}" "lib/scout-tools.sh"
assert_contains "scout-extract-run.sh builds its claude flags from the scope" "${runner_body}" "scout_extract_claude_scope"

# No call site may still pass the raw allowlist flag by hand: if it did, that path would run on the old
# --allowedTools-only posture with no permission mode, which is exactly the hole #1026 closes. Comment
# lines are stripped first, so the header's account of the old flag (valuable history) is not mistaken for
# a live call site: the invariant is that no COMMAND passes --allowedTools, not that the word never appears.
runner_code="$(printf '%s\n' "${runner_body}" | grep -v '^[[:space:]]*#')"
if printf '%s' "${runner_code}" | grep -q -- '--allowedTools'; then
  fail "scout-extract-run.sh still hardcodes --allowedTools on a call site" \
       "every claude invocation must fold through scout_extract_claude_scope, or a call site keeps the unrestricted flag"
else
  pass "scout-extract-run.sh hardcodes no --allowedTools flag on any call site; both paths use the scope"
fi

# Count the claude invocations and require each to carry the scope, so a third path added later cannot
# quietly launch without the restriction.
claude_calls="$(printf '%s\n' "${runner_body}" | grep -c '"\$CLAUDE" -p')"
scope_uses="$(printf '%s\n' "${runner_body}" | grep -c 'SCOUT_SCOPE\|scout_extract_claude_scope')"
if [[ "${claude_calls}" -ge 2 && "${scope_uses}" -ge "${claude_calls}" ]]; then
  pass "every claude invocation (${claude_calls}) carries the scope (${scope_uses} references)"
else
  fail "each claude invocation must carry the scope" "claude calls: ${claude_calls}, scope references: ${scope_uses}"
fi

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all scout-tools.sh checks passed"
