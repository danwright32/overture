#!/usr/bin/env bash
set -euo pipefail

# Runs every test suite in this repo, TypeScript and Swift, in one command (#595). The
# repo spans two languages with two independent CI jobs (typecheck-and-test, swift-tests)
# and no single local command ran both; it was easy to run only mac/scripts/run-tests-locked.sh,
# see it pass, and push, only learning the TypeScript side would have failed once CI
# reported it minutes later. This is the one command to run before pushing anything that
# touches a cross-language contract (fixtures/, docs/contracts.md) or, really, anything at all.
#
# Usage: scripts/test-all.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"
echo "==> pnpm typecheck"
pnpm typecheck

echo "==> pnpm test"
pnpm test

echo "==> mac/scripts/run-tests-locked.sh"
"${REPO_ROOT}/mac/scripts/run-tests-locked.sh"

echo "==> all suites passed"
