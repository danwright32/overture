#!/usr/bin/env bash
set -euo pipefail

# Guards against a FUTURE detached claude runner reintroducing the bare --allowedTools hole #1026/#1097
# already closed for the three that exist today (scout-extract, prep, reply-classify).
#
# The bug: a headless `claude -p` inherits the same ~/.claude settings an interactive session has,
# where permissions.defaultMode is "auto". Passing only `--allowedTools "Read,Write,..."` PRE-APPROVES
# those tools; it does NOT restrict a run to them. Under the inherited auto mode every OTHER tool
# (Bash, Edit, Skill, WebSearch, anything the environment exposes) is auto-approved too. A 2026-07-17
# scout run made 13 Bash and 14 Edit calls with ZERO denials, on a run whose own comment claimed "No
# Bash". #1026 fixed scout-extract, #1097 folded prep and reply-classify through the same fix: every
# runner now builds its claude flags from a *_claude_scope function in mac/scripts/lib/claude-run-scope.sh,
# which adds the fail-closed `--permission-mode manual` no detached run can talk its way around.
#
# THE GAP this check closes: nothing stopped a FOURTH runner, added later, from passing a literal
# --allowedTools at its own "$CLAUDE" -p call site instead of folding through a *_claude_scope function,
# quietly reopening the exact hole. mac/scripts/lib/claude-run-scope.test.sh already asserts this for the
# two runners it names by hand (prep-run.sh, reply-classify-run.sh); that assertion never runs against a
# script nobody added to its hardcoded list. This check instead scans every mac/scripts/*.sh file (any
# runner, present or future) generically: whichever ones call "$CLAUDE" -p must fold through a
# *_claude_scope function and must never hardcode --allowedTools directly.
#
# The pure comparison (detached_runner_scope_violations) is covered by
# check-detached-runner-scope.test.sh, which drives it against throwaway fixture text (and a real
# temporary fixture file) so it runs anywhere including CI.
#
# Usage: scripts/check-detached-runner-scope.sh [file ...]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# A call to any *_claude_scope function (prep_claude_scope, scout_extract_claude_scope,
# reply_classify_claude_scope today; whatever a future runner names its own). This is the ONE
# acceptable way a runner may build its claude flags: everything the function emits already carries
# the fail-closed --permission-mode manual from claude-run-scope.sh.
SCOPE_FOLD_PATTERN='[A-Za-z_][A-Za-z0-9_]*_claude_scope'

# Given the raw text of a shell file ($1), prints one line per violation found (empty output means the
# file is fine) and always returns 0 so `set -e` never trips mid scan. Pure: takes text, touches no
# files, so the test drives it directly with throwaway content.
#
# A file that never invokes a detached "$CLAUDE" -p run at all (the common case: everything that is not
# a runner, and lib/claude-run-scope.sh itself, which only DEFINES the scope functions) is not scanned
# further and reports clean. A file that does invoke one is a violation if it hardcodes a literal
# --allowedTools on any live code line, OR if it never calls any *_claude_scope function at all (so the
# emitted flags cannot possibly be the fail-closed ones that function guarantees).
#
# Full-line comments are stripped first (matching check-health-recorder-drift.sh's convention) so the
# many comments in the real runners that NAME --allowedTools to explain the historical bug, or the
# shellcheck directive lines that mention it, are never mistaken for a live call site.
detached_runner_scope_violations() {
  local text="$1"
  local code

  code="$(printf '%s\n' "${text}" | grep -v '^[[:space:]]*#')"

  # No detached headless run in this file: nothing to guard, regardless of what else it contains.
  if ! printf '%s' "${code}" | grep -q '"\$CLAUDE"[[:space:]]*-p'; then
    return 0
  fi

  if printf '%s' "${code}" | grep -q -- '--allowedTools'; then
    echo "hardcodes a literal --allowedTools on a \"\$CLAUDE\" -p call site instead of folding through a *_claude_scope function"
  fi

  if ! printf '%s' "${code}" | grep -Eq "${SCOPE_FOLD_PATTERN}"; then
    echo "invokes \"\$CLAUDE\" -p without calling any *_claude_scope function anywhere in the file"
  fi

  return 0
}

main() {
  local files=("$@")
  if [[ "${#files[@]}" -eq 0 ]]; then
    # Every shell script under mac/scripts, recursively (a future runner could as easily land in
    # mac/scripts/ as in mac/scripts/lib/). *.test.sh fixtures are excluded: they are test harnesses,
    # never launched detached by the app, and this repo's own fixture files legitimately contain the
    # bad pattern as throwaway text to prove the guard catches it, which must never be confused with a
    # real call site.
    while IFS= read -r -d '' f; do
      files+=("${f}")
    done < <(find "${REPO_ROOT}/mac/scripts" -name '*.sh' ! -name '*.test.sh' -print0 | sort -z)
  fi

  local violations=() file text reasons reason
  for file in "${files[@]}"; do
    if [[ ! -f "${file}" ]]; then
      echo "ERROR: file not found at ${file}" >&2
      exit 2
    fi
    text="$(cat "${file}")"
    reasons="$(detached_runner_scope_violations "${text}")"
    while IFS= read -r reason; do
      [[ -z "${reason}" ]] && continue
      violations+=("$(basename "${file}"): ${reason}")
    done <<< "${reasons}"
  done

  if [[ "${#violations[@]}" -eq 0 ]]; then
    echo "OK: every detached \"\$CLAUDE\" -p runner under mac/scripts folds its tool scope through a *_claude_scope function; no bare --allowedTools found."
    exit 0
  fi

  echo "DETACHED RUNNER SCOPE HOLE: a headless claude -p call bypasses claude-run-scope.sh:"
  for reason in "${violations[@]}"; do
    echo "  ${reason}"
  done
  echo
  echo "This is the #1026/#1097 shape: --allowedTools alone only PRE-APPROVES the tools it names, it"
  echo "does not restrict a run to them, so under the inherited auto permission mode every other tool"
  echo "is silently auto-approved too. Fold this runner's \"\$CLAUDE\" -p call through a *_claude_scope"
  echo "function in mac/scripts/lib/claude-run-scope.sh (see scout_extract_claude_scope, prep_claude_scope,"
  echo "reply_classify_claude_scope for the pattern) instead of passing --allowedTools directly."
  exit 1
}

# Sourceable without running (the test sources this to drive detached_runner_scope_violations
# directly). Mirrors the convention in check-health-recorder-drift.sh, merge-when-green.sh and
# check-pr-ci.sh.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
