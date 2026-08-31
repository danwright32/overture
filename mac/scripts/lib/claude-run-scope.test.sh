#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"

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

# A stand-in claude binary whose `plugin list --json` prints exactly what a case wants to test, so the
# plugin half of the scope is driven by a listing this file controls rather than by whatever happens to
# be installed on the Mac running the suite. That is the whole point of #1682: the list must be DERIVED
# from the machine, so a fixture that hardcoded Dan's current seven plugins would assert nothing.
STUB_ROOT="$(fixture_scratch_dir)"
trap 'rm -rf "${STUB_ROOT}"' EXIT

# stub_claude <plugin-list-json> [exit-status]: prints the path to a fresh executable stub.
#
# Each call gets its own mktemp directory rather than a counter: this function is always invoked inside a
# command substitution, which is a subshell, so a counter incremented here never reaches the parent and
# every stub would overwrite the first one. Written the counting way first, the stub that must FAIL
# silently replaced the stub that must SUCCEED, and cases that had already passed started failing.
stub_claude() {
  local body="$1" status="${2:-0}" dir
  dir="$(mktemp -d "${STUB_ROOT}/stub.XXXXXX")"
  {
    echo '#!/bin/sh'
    echo "cat <<'STUB_JSON'"
    printf '%s\n' "${body}"
    echo 'STUB_JSON'
    echo "exit ${status}"
  } > "${dir}/claude"
  chmod +x "${dir}/claude"
  printf '%s' "${dir}/claude"
}

# The shape `claude plugin list --json` really prints, captured from the live command on 2026-07-28,
# trimmed to the fields this parser reads. Two invented ids, so a scope that echoed the real machine's
# plugins instead of deriving from this listing fails loudly.
TWO_PLUGINS='[
  {
    "id": "alpha@marketplace-one",
    "version": "1.0.0",
    "scope": "user",
    "enabled": true,
    "installPath": "/tmp/alpha",
    "mcpServers": {
      "alpha-api": {
        "type": "http",
        "url": "https://example.invalid/mcp"
      }
    }
  },
  {
    "id": "beta@marketplace-two",
    "version": "2.0.0",
    "scope": "user",
    "enabled": true,
    "installPath": "/tmp/beta"
  }
]'

STUB_TWO="$(stub_claude "${TWO_PLUGINS}")"

# --- the plugin lockout: what #1682 closes -------------------------------------------------------------
#
# A detached `claude -p` loads every plugin enabled in ~/.claude, and their SessionStart hooks inject
# whatever they like into the run. Measured on 2026-07-28: a vercel plugin pushed 54,486 characters of
# Next.js product documentation into every chunk of a contact hunt, carrying imperatives ("MANDATORY ...
# You MUST ...") in the same voice this repo's runbooks use. This repo goes to real trouble to control
# exactly what a detached run is told (#1026, runner-prompts.test.sh, check-detached-runner-scope.sh) and
# a plugin installed for a different project walked past all of it.
#
# The fix has to enumerate: --settings MERGES enabledPlugins per key rather than replacing the object, so
# an empty map disables nothing (measured, both ways). And the list has to be DERIVED from the machine,
# because a hardcoded one goes stale silently the next time a plugin is installed.

lockout="$(claude_run_plugin_lockout "${STUB_TWO}" "unit")"
lockout_status=$?
[[ "${lockout_status}" -eq 0 ]] || fail "the plugin lockout emits cleanly on a real listing" "returned ${lockout_status}"
assert_contains "the lockout turns off every plugin the listing names" "${lockout}" \
  '--settings {"enabledPlugins":{"alpha@marketplace-one":false,"beta@marketplace-two":false}}'

# Derived, not hardcoded: nothing installed on THIS Mac may leak into a scope built from that listing.
assert_not_contains "the lockout names no plugin the listing did not" "${lockout}" "vercel"

# The same listing on ONE line must read identically. A first cut matched only an id anchored to the start
# of its own line, which read nothing at all out of compact JSON and would have emitted a map that turned
# nothing off, reporting success the whole way.
compact="$(claude_run_plugin_lockout "$(stub_claude '[{"id":"alpha@marketplace-one","enabled":true},{"id":"beta@marketplace-two","enabled":true}]')" "unit")"
assert_contains "the lockout reads a compact one-line listing the same as a pretty-printed one" "${compact}" \
  '--settings {"enabledPlugins":{"alpha@marketplace-one":false,"beta@marketplace-two":false}}'

# The runners splice the scope onto the command line by deliberate word-splitting, so a space anywhere in
# the emitted JSON would break the flag into pieces and hand claude a garbage argument.
if [[ "${lockout#--settings }" == *" "* ]]; then
  fail "the lockout's settings JSON must contain no spaces" "emitted: ${lockout}"
else
  pass "the lockout's settings JSON contains no spaces, so it survives the runners' word-splitting"
fi

# Failure path: no claude binary to ask. Refuse loudly rather than emit a scope that turns nothing off.
out="$(claude_run_plugin_lockout "" "unit" 2>/dev/null)"
st=$?
if [[ "${st}" -ne 0 && -z "${out}" ]]; then
  pass "the lockout refuses when it is handed no claude binary"
else
  fail "the lockout must refuse when handed no claude binary" "status ${st}, emitted: ${out}"
fi

# Failure path: the listing command itself fails. An unreadable plugin list is NOT "no plugins".
out="$(claude_run_plugin_lockout "$(stub_claude '' 1)" "unit" 2>/dev/null)"
st=$?
if [[ "${st}" -ne 0 && -z "${out}" ]]; then
  pass "the lockout refuses when 'claude plugin list --json' fails"
else
  fail "the lockout must refuse when the plugin listing fails" "status ${st}, emitted: ${out}"
fi

# Failure path: the command succeeds but prints something that is not the documented array.
out="$(claude_run_plugin_lockout "$(stub_claude 'plugin listing unavailable')" "unit" 2>/dev/null)"
st=$?
if [[ "${st}" -ne 0 && -z "${out}" ]]; then
  pass "the lockout refuses a plugin listing that is not a JSON array"
else
  fail "the lockout must refuse a listing that is not a JSON array" "status ${st}, emitted: ${out}"
fi

# Failure path: the array holds plugins but the field this parser reads has been renamed. This is the one
# that would otherwise fail SILENTLY, emitting an empty map that disables nothing while reporting success.
out="$(claude_run_plugin_lockout "$(stub_claude '[{"identifier":"alpha@marketplace-one","enabled":true}]')" "unit" 2>/dev/null)"
st=$?
if [[ "${st}" -ne 0 && -z "${out}" ]]; then
  pass "the lockout refuses a listing whose entries carry no readable id"
else
  fail "the lockout must refuse a listing whose entries carry no readable id" "status ${st}, emitted: ${out}"
fi

# ...but a genuinely empty listing is a real, honest answer: nothing installed, nothing to turn off.
empty_lockout="$(claude_run_plugin_lockout "$(stub_claude '[]')" "unit")"
empty_status=$?
if [[ "${empty_status}" -eq 0 ]]; then
  assert_contains "an empty plugin listing still emits the flag, with nothing to disable" "${empty_lockout}" \
    '--settings {"enabledPlugins":{}}'
else
  fail "the lockout must accept an empty plugin listing" "returned ${empty_status}"
fi

# --- the generic guard, directly -----------------------------------------------------------------------

# Happy path: it emits all three flags, in the shape the runners splice onto the claude command line.
generic="$(claude_run_scope "Read,Write" "manual" "Bash Edit" "unit" "${STUB_TWO}")"
generic_status=$?
[[ "${generic_status}" -eq 0 ]] || fail "the generic guard emits cleanly on a safe scope" "returned ${generic_status}"
assert_contains "the generic guard pre-approves exactly the tools it is given" "${generic}" "--allowedTools Read,Write"
assert_contains "the generic guard carries the permission mode it is given" "${generic}" "--permission-mode manual"
assert_contains "the generic guard turns off this machine's plugins too (#1682)" "${generic}" '--settings {"enabledPlugins":{'

# Failure path: an unreadable plugin listing must sink the WHOLE scope, not just its own flag. A run that
# started with the tool boundary intact but every installed plugin still injecting is the #1682 hole.
out="$(claude_run_scope "Read,Write" "manual" "" "unit" "$(stub_claude '' 1)" 2>/dev/null)"
st=$?
if [[ "${st}" -ne 0 && -z "${out}" ]]; then
  pass "the generic guard refuses outright when the plugins cannot be turned off"
else
  fail "the generic guard must refuse when the plugins cannot be turned off" "status ${st}, emitted: ${out}"
fi

# Failure path: an empty or auto-approving mode is the whole bug (an allowlist with nothing closing the
# door behind it), so the guard must refuse and emit nothing.
for dangerous in auto bypassPermissions dontAsk acceptEdits ""; do
  out="$(claude_run_scope "Read,Write" "${dangerous}" "" "unit" "${STUB_TWO}" 2>/dev/null)"
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
  if claude_run_scope "Read,Write" "${safe}" "" "unit" "${STUB_TWO}" >/dev/null 2>&1; then
    pass "the generic guard accepts the fail-closed mode '${safe}'"
  else
    fail "the generic guard must accept the fail-closed mode '${safe}'"
  fi
done

# Failure path: a forbidden tool that has crept into the allowlist must be refused, loudly. Matched with
# commas around both sides so "WebFetch" can never match "WebSearch" nor "Read" a substring of another.
out="$(claude_run_scope "Read,Write,Edit" "manual" "Bash Edit" "unit" "${STUB_TWO}" 2>/dev/null)"
st=$?
if [[ "${st}" -ne 0 && -z "${out}" ]]; then
  pass "the generic guard refuses an allowlist that smuggles in a forbidden tool"
else
  fail "the generic guard must refuse a forbidden tool in the allowlist" "status ${st}, emitted: ${out}"
fi
# ...but a forbidden name that is only a SUBSTRING of an allowed tool must NOT trip the guard.
if claude_run_scope "Read,Write,WebFetch" "manual" "WebSearch" "unit" "${STUB_TWO}" >/dev/null 2>&1; then
  pass "the generic guard does not confuse WebFetch in the allowlist with a forbidden WebSearch"
else
  fail "the generic guard wrongly refused WebFetch when only WebSearch is forbidden"
fi

# --- prep's scope: the run that writes emails reaching strangers in Dan's voice ------------------------
#
# Prep DELIBERATELY needs Bash and Skill (it drives research and invokes the dan-wright-brand-voice
# skill), so this is not a copy of the scout posture. What must stay true is that the mode closes the door
# on everything ELSE (Edit above all: the 2026-07-17 scout run made 14 Edit calls it was never granted).
prep="$(prep_claude_scope "${STUB_TWO}")"
prep_status=$?
[[ "${prep_status}" -eq 0 ]] || fail "the prep scope emits cleanly" "returned ${prep_status}"
assert_contains "prep pre-approves the six tools its job needs" "${prep}" "--allowedTools Read,Write,WebSearch,WebFetch,Bash,Skill"
assert_contains "prep carries the fail-closed permission mode" "${prep}" "--permission-mode manual"
assert_contains "prep can invoke the brand-voice skill its prompt names" "${prep}" "Skill"
assert_contains "prep turns off every plugin installed on the machine (#1682)" "${prep}" \
  '--settings {"enabledPlugins":{"alpha@marketplace-one":false,"beta@marketplace-two":false}}'
# Edit is the tool a run must never regain here; the mode denies it, and it must not sit in the allowlist.
assert_not_contains "prep does not pre-approve Edit" "${prep}" "Edit"
# And if a later edit adds Edit to the allowlist, the guard must refuse rather than emit it.
if PREP_ALLOWED_TOOLS="Read,Write,Edit" prep_claude_scope "${STUB_TWO}" >/dev/null 2>&1; then
  fail "the prep scope must refuse an allowlist that adds Edit"
else
  pass "the prep scope refuses an allowlist that adds Edit"
fi
# A prep run launched without a claude binary to enumerate plugins with must refuse, not run wide open.
if prep_claude_scope >/dev/null 2>&1; then
  fail "the prep scope must refuse when it cannot enumerate the machine's plugins"
else
  pass "the prep scope refuses when it cannot enumerate the machine's plugins"
fi
# And if the mode is ever cleared back to the inherited auto, prep must refuse too.
if PREP_PERMISSION_MODE="" prep_claude_scope "${STUB_TWO}" >/dev/null 2>&1; then
  fail "the prep scope must refuse an empty permission mode (it would inherit auto)"
else
  pass "the prep scope refuses an empty permission mode"
fi

# --- reply-classify's scope: the tightest of the three ------------------------------------------------
#
# It reads the work-list and the voice guidance, drafts a reply, and writes results. It needs Read, Write
# and Skill (to invoke the brand-voice skill), and nothing else: no Bash, no Edit, no web access at all.
reply="$(reply_classify_claude_scope "${STUB_TWO}")"
reply_status=$?
[[ "${reply_status}" -eq 0 ]] || fail "the reply-classify scope emits cleanly" "returned ${reply_status}"
assert_contains "reply-classify pre-approves exactly Read, Write and Skill" "${reply}" "--allowedTools Read,Write,Skill"
assert_contains "reply-classify carries the fail-closed permission mode" "${reply}" "--permission-mode manual"
assert_contains "reply-classify can invoke the brand-voice skill its prompt names" "${reply}" "Skill"
assert_contains "reply-classify turns off every plugin installed on the machine (#1682)" "${reply}" \
  '--settings {"enabledPlugins":{"alpha@marketplace-one":false,"beta@marketplace-two":false}}'
for never in Bash Edit WebFetch WebSearch; do
  assert_not_contains "reply-classify does not pre-approve ${never}" "${reply}" "${never}"
  if REPLY_CLASSIFY_ALLOWED_TOOLS="Read,Write,Skill,${never}" reply_classify_claude_scope "${STUB_TWO}" >/dev/null 2>&1; then
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

  if grep -q -- '--allowedTools' <<< "${code}"; then
    fail "${script} still hardcodes --allowedTools on a call site" \
         "every claude invocation must fold through ${scope_fn}, or a call site keeps the unrestricted flag"
  else
    pass "${script} hardcodes no --allowedTools flag on any call site"
  fi

  # #1682: the scope needs the claude binary to enumerate this Mac's plugins with, so each runner must
  # resolve that binary BEFORE it builds the scope and hand it over. Built is not wired: a runner that
  # still called its scope function with no argument would refuse and never start at all.
  local resolve_line scope_line
  if grep -qF "${scope_fn} \"\$CLAUDE\"" <<< "${code}"; then
    pass "${script} hands the resolved claude binary to ${scope_fn}"
  else
    fail "${script} must call ${scope_fn} \"\$CLAUDE\"" \
         "without the binary the scope cannot enumerate this Mac's plugins, so it refuses and the run never starts"
  fi
  resolve_line="$(grep -n -m1 '^resolve_claude' <<< "${code}" | cut -d: -f1)"
  scope_line="$(grep -n -m1 "${scope_fn} \"\$CLAUDE\"" <<< "${code}" | cut -d: -f1)"
  if [[ -n "${resolve_line}" && -n "${scope_line}" && "${resolve_line}" -lt "${scope_line}" ]]; then
    pass "${script} resolves the claude binary before building its scope"
  else
    fail "${script} must call resolve_claude before ${scope_fn}" \
         "resolve_claude at line ${resolve_line:-none}, scope built at line ${scope_line:-none}"
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

# --- the MCP lockout (#2386) ---------------------------------------------------------------------------
#
# The plugin lockout above decides what a detached run is TOLD. This decides what it is OFFERED. Same
# hole, third time: MCP servers are not plugins, so #1682's lockout never touched them, and a headless
# `claude -p` on this Mac loads every configured server.
#
# Measured on the wire 2026-08-29 with a trivial prompt: 53 distinct `mcp__` tools reach the run, and
# `--strict-mcp-config` takes that to 0 while the run still answers and the dan-wright-brand-voice skill
# is still loaded, which is the constraint #1682 established and the reason `--setting-sources` is not
# the route. The 2026-08-09 reachability check reached for two of those tools (`browser_navigate`) and
# was refused, which is the whole content of a "web lookups refused" line on a run where 338 landed.
#
# Unlike the plugin half there is nothing to ENUMERATE and so nothing to refuse over: the flag means
# "only the servers named by --mcp-config", none is passed, and that is zero by construction rather than
# by a list that could go stale. A claude too old for the flag is not a silent hole either, measured the
# same day: an unknown option makes it exit with `error: unknown option`, so the run dies loudly instead
# of quietly running unscoped. A probe of `--help` would guard nothing that is not already loud, and a
# guard that cannot be seen to fail is one nobody can trust (L1).

for scope_pair in "prep:$(prep_claude_scope "${STUB_TWO}")"                   "reply-classify:$(reply_classify_claude_scope "${STUB_TWO}")"; do
  scope_name="${scope_pair%%:*}"
  scope_text="${scope_pair#*:}"
  assert_contains "the ${scope_name} scope carries the MCP lockout" "${scope_text}" "--strict-mcp-config"
done

# It is part of the SCOPE, so a refused scope emits it no more than it emits the allowlist. A run that
# started with the MCP surface closed and every plugin still injecting is the #1682 hole itself, and the
# mirror of that is just as wrong: nothing may leak out of a refusal (L42).
refused_scope="$(claude_run_scope "Read" "auto" "" "unit" "${STUB_TWO}" 2>/dev/null)"
assert_not_contains "an unsafe permission mode emits no MCP flag either" "${refused_scope}" "--strict-mcp-config"
refused_scope="$(claude_run_scope "Read" "manual" "" "unit" "$(stub_claude '' 1)" 2>/dev/null)"
assert_not_contains "an unreadable plugin listing emits no MCP flag either" "${refused_scope}" "--strict-mcp-config"

# And the flag is spliced by deliberate word splitting like the rest of the scope, so it must carry no
# space of its own or it arrives at claude as two broken arguments.
assert_equals "the MCP lockout is one word, so word splitting cannot break it" \
  "1" "$(printf '%s' "${CLAUDE_RUN_MCP_LOCKOUT}" | wc -w | tr -d ' ')"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all claude-run-scope.sh checks passed"
