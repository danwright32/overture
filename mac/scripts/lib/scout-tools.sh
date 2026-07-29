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
#
# #1097: the guard itself (the mode check, the forbidden-tool check, the fail-loud refusal) now lives in
# lib/claude-run-scope.sh, shared with the prep and reply-classify runners so it cannot be right here and
# a drifted near-copy there. This file keeps only scout's OWN posture (its three tools, its forbidden set)
# and delegates the enforcement.
. "$(dirname "${BASH_SOURCE[0]}")/claude-run-scope.sh"

# The tools this run is allowed to call. Exactly the three its job needs.
SCOUT_EXTRACT_ALLOWED_TOOLS="Read,Write,WebFetch"

# The fail-closed permission mode. It must NOT be one that auto-approves tools outside the allowlist:
# "auto", "bypassPermissions", "dontAsk" and "acceptEdits" all would, and an empty mode falls back to the
# inherited auto, which is the whole bug. "manual" (and "plan") instead require an approval no detached
# run can supply, so the allowlist becomes a hard boundary rather than a mere pre-approval.
SCOUT_EXTRACT_PERMISSION_MODE="manual"

# Tools this run must NEVER be able to call, enumerated so the guard can prove none has crept into the
# allowlist through a later edit. Bash and Edit are the two the 2026-07-17 run actually used.
SCOUT_EXTRACT_FORBIDDEN_TOOLS="Bash Edit Skill WebSearch"

# Emits the claude flags that scope the scout-extract run, refusing loudly on an unsafe posture. Thin
# wrapper over the shared guard so scout's public name and its env-overridable globals stay unchanged
# (the runner and its own fixture still call scout_extract_claude_scope exactly as before).
scout_extract_claude_scope() {
  claude_run_scope "${SCOUT_EXTRACT_ALLOWED_TOOLS}" "${SCOUT_EXTRACT_PERMISSION_MODE}" \
    "${SCOUT_EXTRACT_FORBIDDEN_TOOLS}" "scout-extract" "${1:-}"
}
