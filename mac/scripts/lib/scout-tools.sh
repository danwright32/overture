#!/usr/bin/env bash
# #1026: the tool scope for the DETACHED scout-extract run, in ONE place.
#
# This run reads UNTRUSTED web content (the pinned org pages the app fetched, and each event's own detail
# page it follows with WebFetch) and writes the outreach data Dan later pitches from. Its job needs
# exactly three tools: Read (the local pinned page), WebFetch (the detail page), Write (the results
# file). It needs no others.
#
# Before #1026 the runner passed only `--allowedTools "Read,Write,WebFetch"`, and its comment said "No
# Bash, no Skill, no WebSearch". That was false. `--allowedTools` PRE-APPROVES those three; it does not
# RESTRICT to them. The run is launched detached by the app, and a headless `claude -p` inherits the same
# ~/.claude settings an interactive session does, where `permissions.defaultMode` is "auto". Under auto,
# every OTHER tool (Bash, Edit, Skill, WebSearch) is auto-approved too. A 2026-07-17 sonnet run made 13
# Bash calls and 14 Edit calls with ZERO denials, on a run the code claimed had no shell at all.
#
# The fix is `--permission-mode manual`, which OVERRIDES the inherited auto. Under manual anything outside
# the allowlist needs an approval, and a detached run has nobody to give one, so the tool is DENIED (it
# does not hang: the headless run continues and finishes). Verified by hand on 2026-07-17: with
# `--allowedTools "Read,Write,WebFetch" --permission-mode manual`, a Bash `touch` and an Edit were both
# blocked while a Write still succeeded; with the same allowlist and no mode flag (inheriting auto), the
# same Bash `touch` ran. So the mode flag, not the allowlist, is what makes the stated posture real.
#
# One file, so the restriction cannot be right on one launch path and missing on the other. The runner
# launches claude in two places (one per chunk, and a single-process fallback on a node-free machine);
# both build their flags from scout_extract_claude_scope below.

# The tools this run is allowed to call. Exactly the three its job needs.
SCOUT_EXTRACT_ALLOWED_TOOLS="Read,Write,WebFetch"

# The fail-closed permission mode. It must NOT be one that auto-approves tools outside the allowlist:
# "auto", "bypassPermissions", "dontAsk" and "acceptEdits" all would, and an empty mode falls back to the
# inherited auto, which is the whole bug. "manual" (and "plan") instead require an approval no detached
# run can supply, so the allowlist becomes a hard boundary rather than a mere pre-approval.
SCOUT_EXTRACT_PERMISSION_MODE="manual"

# The permission modes that leave tools outside the allowlist reachable. If SCOUT_EXTRACT_PERMISSION_MODE
# is ever set to one of these (or left empty), the scope function refuses to emit and the run fails loud.
SCOUT_EXTRACT_UNSAFE_MODES="auto bypassPermissions dontAsk acceptEdits"

# Tools this run must NEVER be able to call, enumerated so the guard can prove none has crept into the
# allowlist through a later edit. Bash and Edit are the two the 2026-07-17 run actually used.
SCOUT_EXTRACT_FORBIDDEN_TOOLS="Bash Edit Skill WebSearch"

# Emits the claude flags that scope the scout-extract run, and REFUSES (returns nonzero, emits nothing) if
# the scope has drifted into an unsafe posture: an auto-approving (or empty) permission mode, or a
# forbidden tool smuggled into the allowlist. Failing loud here is deliberate: a partial or unsafe scope
# is worse than none, because it would silently hand a detached run reading untrusted pages a shell again.
scout_extract_claude_scope() {
  local mode="${SCOUT_EXTRACT_PERMISSION_MODE}"

  # The mode must not be empty (which falls back to the inherited auto) or any approve-everything mode.
  if [ -z "${mode}" ]; then
    echo "scout-extract: refusing to run: no permission mode set (an empty mode inherits the auto-approve default)" >&2
    return 1
  fi
  local unsafe
  for unsafe in ${SCOUT_EXTRACT_UNSAFE_MODES}; do
    if [ "${mode}" = "${unsafe}" ]; then
      echo "scout-extract: refusing to run: permission mode '${mode}' auto-approves tools outside the allowlist" >&2
      return 1
    fi
  done

  # No forbidden tool may appear in the allowlist. Compared with commas around both sides so "WebFetch"
  # can never match "WebSearch" and "Read" can never match a substring of another tool name.
  local forbidden
  for forbidden in ${SCOUT_EXTRACT_FORBIDDEN_TOOLS}; do
    case ",${SCOUT_EXTRACT_ALLOWED_TOOLS}," in
      *",${forbidden},"*)
        echo "scout-extract: refusing to run: '${forbidden}' must never be in the scout allowlist" >&2
        return 1 ;;
    esac
  done

  printf '%s' "--allowedTools ${SCOUT_EXTRACT_ALLOWED_TOOLS} --permission-mode ${mode}"
}
