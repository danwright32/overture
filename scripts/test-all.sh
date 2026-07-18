#!/usr/bin/env bash
set -euo pipefail

# Runs every test suite in this repo, TypeScript and Swift, in one command (#595). The
# repo spans two languages with two independent CI jobs (typecheck-and-test, swift-tests)
# and no single local command ran both; it was easy to run only mac/scripts/run-tests-locked.sh,
# see it pass, and push, only learning the TypeScript side would have failed once CI
# reported it minutes later. This is the one command to run before pushing anything that
# touches a cross-language contract (fixtures/, docs/contracts.md) or, really, anything at all.
#
# #698: also runs every scripts/*.test.sh and mac/scripts/**/*.test.sh fixture (the pure-function
# tests for check-pr-ci.sh, merge-when-green.sh, run-tests-locked.sh, etc.), which previously only
# ran when someone remembered to run them by hand.
#
# Usage: scripts/test-all.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"
echo "==> pnpm typecheck"
pnpm typecheck

echo "==> pnpm test"
pnpm test

echo "==> scripts/run-shell-fixtures.sh"
"${REPO_ROOT}/scripts/run-shell-fixtures.sh"

# Warns if docs/prep-runbook.md and the external dan-wright-brand-voice skill have drifted apart
# (#731). Skips cleanly (exit 0) on any machine without the skill installed, since it lives outside
# this clone, so it never breaks CI or a fresh checkout; it only fails locally on genuine drift.
echo "==> scripts/check-brand-voice-drift.sh"
"${REPO_ROOT}/scripts/check-brand-voice-drift.sh"

# Fails if a second near-copy source-health recorder has been reintroduced in the scout ingest files
# (#1073). The #987/#1001/#1005 defect (two recorders drifting until one silently stops writing a
# field) is caught at push time instead of in production.
echo "==> scripts/check-health-recorder-drift.sh"
"${REPO_ROOT}/scripts/check-health-recorder-drift.sh"

# Fails if any detached "$CLAUDE" -p runner under mac/scripts hardcodes a literal --allowedTools
# instead of folding through a *_claude_scope function in mac/scripts/lib/claude-run-scope.sh (#1102).
# Guards against a FUTURE fourth runner reintroducing the bare --allowedTools hole #1026/#1097 already
# closed for scout-extract, prep and reply-classify.
echo "==> scripts/check-detached-runner-scope.sh"
"${REPO_ROOT}/scripts/check-detached-runner-scope.sh"

echo "==> mac/scripts/run-tests-locked.sh"
"${REPO_ROOT}/mac/scripts/run-tests-locked.sh"

echo "==> all suites passed"
