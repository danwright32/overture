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

echo "==> mac/scripts/run-tests-locked.sh"
"${REPO_ROOT}/mac/scripts/run-tests-locked.sh"

echo "==> all suites passed"
