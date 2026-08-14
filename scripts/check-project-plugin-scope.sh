#!/usr/bin/env bash
set -euo pipefail

# Fails if this repo's tracked .claude/settings.json stops disabling the Claude Code plugins that have
# no business being loaded here (#2605).
#
# What it guards. Plugins are enabled at USER scope in ~/.claude/settings.json, so they fire in every
# project on this Mac regardless of what the project is. Measured on 2026-08-13 in one session opened in
# this repo with a single one-line prompt, the Vercel plugin's SessionStart hook injected 53.2KB of
# Vercel product documentation (large enough that the harness spilled it to a file rather than showing
# it), a second hook nagged that the Vercel CLI was outdated, and its UserPromptSubmit hook matched the
# prompt by lexical recall and injected "You must run the Skill(...)" lines under a heading reading
# "MANDATORY: Your training data for these libraries is OUTDATED and UNRELIABLE". None of it is true of
# this repo: Overture is a SwiftUI Mac app plus a small tsx importer, with no Vercel deployment, no
# Next.js and no vercel.json.
#
# #1682 fixed the identical plugin doing the identical thing to the DETACHED runs
# (claude_run_plugin_lockout in mac/scripts/lib/claude-run-scope.sh), and deliberately covered only the
# runs this repo launches. The INTERACTIVE session, the one Dan and every agent works in, was never in
# that scope, so the same text kept arriving there.
#
# Why a check at all. The fix is one entry in a tracked settings file, and a config value nothing
# asserts is exactly the kind of thing a later edit re-enables silently. The symptom, a wall of
# injected documentation at the top of a session, reads as normal to anyone who has not met this issue,
# so there is no person who would notice. The pure comparison below is covered by
# check-project-plugin-scope.test.sh, which drives it against throwaway settings text and is seen to go
# red when the tracked value is flipped back to true.
#
# Usage: scripts/check-project-plugin-scope.sh [settings-json-path]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The plugin ids this repo requires its project settings to turn off.
#
# Vercel is the one that was MEASURED doing it (the numbers above). The other three are Dan's call,
# 2026-08-13, asked for in the same breath as the measurement: Cloudflare, Figma and Stripe have no
# more to do with a SwiftUI app plus a tsx importer than Vercel does, and every one of them
# contributes skills, agents and hook text that every session in this repo pays for whether or not it
# has been caught injecting a wall of documentation yet. So the rule here is relevance to this repo,
# not evidence of past misbehaviour.
#
# Three plugins are deliberately NOT here, because they are load bearing: swift-lsp (this is a Swift
# repo), superpowers (its skills are invoked by name in this repo's own workflow), and plannotator
# (Dan reviews plans and diffs through it).
#
# The check walks the whole list, so adding or removing an id needs no other edit here. Its fixture
# names the same four independently rather than reading them back from this array, so dropping one
# from both this list and the settings file still goes red (L70).
PROJECT_DISABLED_PLUGINS=(
  "vercel-plugin@vercel-vercel-plugin"
  "cloudflare@cloudflare"
  "figma@claude-plugins-official"
  "stripe@claude-plugins-official"
)

# project_plugin_scope_violations <settings-json-text> <plugin-id>...
#
# Prints one line per plugin that this settings text does not turn off (empty output means every named
# plugin is disabled) and always returns 0, so `set -e` never trips mid check.
#
# Claude Code's precedence is user < project < local < flag < policy, and a false at project level
# overrides a true in ~/.claude/settings.json. Only a literal false disables a plugin, which is why
# absent and null are reported rather than accepted: with no project-level entry the user-scope true
# wins, so "there is no entry" leaves the plugin exactly as loaded as an explicit true does.
#
# Unparseable text gets its own message rather than being folded into "left enabled" (L11): the fix is
# different, and settings Claude Code cannot parse means it is applying no project entry at all.
project_plugin_scope_violations() {
  local text="$1"
  shift

  if ! printf '%s' "${text}" | jq -e . >/dev/null 2>&1; then
    echo "the project settings could not be read as JSON, so Claude Code is applying none of it"
    return 0
  fi

  local plugin_id value
  for plugin_id in "$@"; do
    # Asked with has() rather than `// "absent"`, because jq's alternative operator treats false as
    # empty, so the one value this check is looking for would have read as a missing entry.
    value="$(printf '%s' "${text}" | jq -r --arg id "${plugin_id}" '
      if (.enabledPlugins | type) == "object" and (.enabledPlugins | has($id))
      then (.enabledPlugins[$id] | tostring)
      else "absent"
      end')"
    case "${value}" in
      false)
        ;;
      absent | null)
        echo "the project settings carries no entry for ${plugin_id}, so the user-scope setting decides and it stays loaded"
        ;;
      *)
        echo "${plugin_id} is left enabled by the project settings (value: ${value})"
        ;;
    esac
  done

  return 0
}

main() {
  local settings_path="${1:-${REPO_ROOT}/.claude/settings.json}"

  # A missing file is a failure, never a quiet pass: no file is the state this repo was in before #2605,
  # and it is exactly when the plugin IS loaded (L98).
  if [[ ! -f "${settings_path}" ]]; then
    echo "FAIL - no project settings at ${settings_path}"
    echo "  Without it, every plugin enabled in ~/.claude/settings.json loads in this repo. Restore the"
    echo "  tracked file, giving each of these a false under \"enabledPlugins\":"
    printf '    %s\n' "${PROJECT_DISABLED_PLUGINS[@]}"
    return 1
  fi

  local text violations
  text="$(cat "${settings_path}")"
  violations="$(project_plugin_scope_violations "${text}" "${PROJECT_DISABLED_PLUGINS[@]}")"

  if [[ -z "${violations}" ]]; then
    echo "ok - project settings disable ${#PROJECT_DISABLED_PLUGINS[@]} plugin(s) that do not belong in this repo"
    return 0
  fi

  echo "FAIL - ${settings_path} no longer turns off every plugin this repo disables"
  printf '  %s\n' "${violations}"
  echo "  Every session in this repo, Dan's own and every agent's, then opens carrying that plugin's"
  echo "  injected text and pays tokens for it on every prompt (#2605)."
  return 1
}

# Allow this file to be sourced by its fixture without running main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
