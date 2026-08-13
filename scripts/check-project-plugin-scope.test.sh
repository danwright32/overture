#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501).
# shellcheck source=./lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"

# Pure-function coverage for check-project-plugin-scope.sh's project_plugin_scope_violations (#2605),
# plus the integration check that this repo's own tracked .claude/settings.json really does disable the
# plugin it names.
#
# The load-bearing mutation is `red (enabled)`: flip the tracked value from false to true and this
# fixture must go red. Without that, the settings entry is a config value nothing asserts, and the
# symptom of its removal (a wall of injected Vercel documentation at the top of every session) reads as
# normal to anyone who has not met #2605.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=./check-project-plugin-scope.sh
source "${SCRIPT_DIR}/check-project-plugin-scope.sh"
# check-project-plugin-scope.sh's own `set -euo pipefail` is now active. Turn errexit off so one
# failing assertion doesn't abort the rest of the run.
set +e

FAILURES=0

# Runs project_plugin_scope_violations over throwaway settings text, capturing its printed lines in
# OUT and their count in COUNT.
run_detect() {
  OUT="$(project_plugin_scope_violations "$1" "vercel-plugin@vercel-vercel-plugin")"
  if [[ -z "${OUT}" ]]; then
    COUNT=0
  else
    COUNT="$(printf '%s\n' "${OUT}" | grep -c '^')"
  fi
}

# GREEN: the shape this repo ships. A false at project level overrides the true in ~/.claude/settings.json.
run_detect '{ "enabledPlugins": { "vercel-plugin@vercel-vercel-plugin": false } }'
assert_eq "green: an explicit false for the named plugin is no violation" "0" "${COUNT}"

# GREEN: other keys alongside it are none of this check's business.
run_detect '{
  "permissions": { "allow": ["Bash(ls:*)"] },
  "enabledPlugins": { "vercel-plugin@vercel-vercel-plugin": false, "superpowers@superpowers-dev": true }
}'
assert_eq "green: unrelated settings keys and other plugins do not matter" "0" "${COUNT}"

# RED (the mutation this guard exists to catch): the value flipped back to true, which is what a later
# edit would do, and what the user-scope setting already says.
run_detect '{ "enabledPlugins": { "vercel-plugin@vercel-vercel-plugin": true } }'
if [[ "${COUNT}" -ge 1 ]]; then
  echo "ok - red (enabled): a true for the named plugin is flagged"
else
  echo "FAIL - red (enabled): expected a violation, got none"
  FAILURES=$((FAILURES + 1))
fi
assert_contains "red (enabled): says the plugin is left enabled" "${OUT}" "is left enabled"
assert_contains "red (enabled): names the plugin" "${OUT}" "vercel-plugin@vercel-vercel-plugin"

# RED: the entry deleted outright. Absent is not disabled: with no project-level entry the user-scope
# true wins, so this must read exactly as badly as an explicit true, and say something different about
# why (L11: distinct causes get distinct messages).
run_detect '{ "enabledPlugins": { "superpowers@superpowers-dev": true } }'
if [[ "${COUNT}" -ge 1 ]]; then
  echo "ok - red (absent): a missing entry is flagged, because absent means the user-scope true wins"
else
  echo "FAIL - red (absent): expected a violation, got none"
  FAILURES=$((FAILURES + 1))
fi
assert_contains "red (absent): says there is no entry at all" "${OUT}" "carries no entry"

# RED: no enabledPlugins object at all, the state of this repo before #2605.
run_detect '{ "permissions": { "allow": [] } }'
if [[ "${COUNT}" -ge 1 ]]; then
  echo "ok - red (no enabledPlugins): a settings file with no plugin map at all is flagged"
else
  echo "FAIL - red (no enabledPlugins): expected a violation, got none"
  FAILURES=$((FAILURES + 1))
fi

# RED: a null value. jq would render this as "null", which is neither true nor false, and Claude Code
# does not treat it as disabled, so it must not read as one here either.
run_detect '{ "enabledPlugins": { "vercel-plugin@vercel-vercel-plugin": null } }'
if [[ "${COUNT}" -ge 1 ]]; then
  echo "ok - red (null): a null value is not a disabled plugin"
else
  echo "FAIL - red (null): expected a violation, got none"
  FAILURES=$((FAILURES + 1))
fi

# RED and DISTINCT: unreadable text. "the settings file could not be parsed" and "the plugin is enabled"
# must never collapse into one message, because the fix for each is different, and unparseable settings
# means Claude Code is not applying the project entry at all.
run_detect '{ "enabledPlugins": { oops'
if [[ "${COUNT}" -ge 1 ]]; then
  echo "ok - red (unparseable): text that is not JSON is a violation of its own"
else
  echo "FAIL - red (unparseable): expected a violation, got none"
  FAILURES=$((FAILURES + 1))
fi
assert_contains "red (unparseable): says the settings could not be read as JSON" "${OUT}" "could not be read as JSON"
assert_not_contains "red (unparseable): does not also claim the plugin is enabled" "${OUT}" "is left enabled"

# Every plugin named is checked, not just the first one, so adding a second id later cannot silently
# check only one of them (L96: a guard driven by a list must actually walk the list).
OUT="$(project_plugin_scope_violations \
  '{ "enabledPlugins": { "a@one": false, "b@two": true } }' "a@one" "b@two")"
assert_contains "every named plugin is checked, not only the first" "${OUT}" "b@two"
assert_not_contains "the disabled one is not reported" "${OUT}" "a@one"

echo
echo "--- integration: the real script against temporary settings files ---"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/check-project-plugin-scope-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

# The four ids are named HERE, not read back from the script's PROJECT_DISABLED_PLUGINS array. A check
# whose expected value and actual value come from the same place can only prove that place is
# self-consistent (L70): reading the array would leave this green after somebody dropped an id from
# both the array and the settings file, which is exactly the change that puts a plugin back into every
# session. Vercel is the one that was measured; Cloudflare, Figma and Stripe are Dan's call
# (2026-08-13), on relevance to this repo rather than on evidence of past misbehaviour.
EXPECTED_DISABLED=(
  "vercel-plugin@vercel-vercel-plugin"
  "cloudflare@cloudflare"
  "figma@claude-plugins-official"
  "stripe@claude-plugins-official"
)

# A settings file disabling exactly the four expected ids, built from the list above so this case is
# testing the wired-up script (file discovery, exit codes) rather than a hand-typed subset of it.
printf '%s\n' "${EXPECTED_DISABLED[@]}" \
  | jq -R . | jq -s '{ enabledPlugins: (map({ (.): false }) | add) }' > "${TMP_DIR}/good.json"
# The same file with the first id flipped back to true: one enabled plugin out of four must fail.
jq '.enabledPlugins["vercel-plugin@vercel-vercel-plugin"] = true' "${TMP_DIR}/good.json" > "${TMP_DIR}/bad.json"

"${SCRIPT_DIR}/check-project-plugin-scope.sh" "${TMP_DIR}/good.json" >/dev/null 2>&1
assert_eq "integration: the real script exits 0 on a settings file that disables the plugin" "0" "$?"

"${SCRIPT_DIR}/check-project-plugin-scope.sh" "${TMP_DIR}/bad.json" >/dev/null 2>&1
BAD_STATUS=$?
if [[ "${BAD_STATUS}" -ne 0 ]]; then
  echo "ok - integration: the real script exits non-zero on a settings file that leaves it enabled"
else
  echo "FAIL - integration: expected a non-zero exit on the bad settings file, got 0"
  FAILURES=$((FAILURES + 1))
fi

# A MISSING settings file must fail, not pass. This is the whole #2605 defect: the repo tracked no
# .claude files at all, and "there is no file" is exactly the state that has to be reported rather than
# waved through (L98: finding nothing to check is not a pass).
"${SCRIPT_DIR}/check-project-plugin-scope.sh" "${TMP_DIR}/does-not-exist.json" >/dev/null 2>&1
MISSING_STATUS=$?
if [[ "${MISSING_STATUS}" -ne 0 ]]; then
  echo "ok - integration: a missing settings file fails rather than reading as nothing to check"
else
  echo "FAIL - integration: expected a non-zero exit on a missing settings file, got 0"
  FAILURES=$((FAILURES + 1))
fi

echo
echo "--- this repo's own tracked .claude/settings.json ---"

"${SCRIPT_DIR}/check-project-plugin-scope.sh"
assert_eq "the repo's tracked project settings pass the real check" "0" "$?"

REAL_SETTINGS="$(cat "${REPO_ROOT}/.claude/settings.json")"
for plugin_id in "${EXPECTED_DISABLED[@]}"; do
  OUT="$(project_plugin_scope_violations "${REAL_SETTINGS}" "${plugin_id}")"
  assert_empty "the tracked settings disable ${plugin_id}" "${OUT}"
done

# The three that must NOT be disabled here, for the same reason in reverse: swift-lsp is the Swift
# language server in a Swift repo, superpowers' skills are invoked by name in this repo's own workflow,
# and plannotator is how Dan reads plans and diffs. Turning any of them off would be a quiet loss of
# something in use, and the sweep that added the other three is exactly when that would happen.
for plugin_id in "swift-lsp@claude-plugins-official" "superpowers@superpowers-dev" "plannotator@plannotator"; do
  OUT="$(project_plugin_scope_violations "${REAL_SETTINGS}" "${plugin_id}")"
  assert_contains "the tracked settings leave ${plugin_id} alone, because it is load bearing here" \
    "${OUT}" "carries no entry"
done

# The file has to be TRACKED, not just present. Dan's call, 2026-08-13: .claude/settings.local.json is
# excluded by his global gitignore and lives per checkout, so every agent worktree would keep getting
# the injected text. Only a tracked file reaches every clone and every worktree without anyone running
# anything.
if git -C "${REPO_ROOT}" ls-files --error-unmatch .claude/settings.json >/dev/null 2>&1; then
  echo "ok - .claude/settings.json is tracked, so every clone and worktree gets it"
else
  echo "FAIL - .claude/settings.json is not tracked by git, so worktrees and fresh clones miss it"
  FAILURES=$((FAILURES + 1))
fi

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "check-project-plugin-scope.test.sh: all assertions passed"
  exit 0
else
  echo "check-project-plugin-scope.test.sh: ${FAILURES} assertion(s) failed"
  exit 1
fi
