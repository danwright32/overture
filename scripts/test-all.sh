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

# #2318: record the working tree before anything runs, and compare it at the end. A test that writes
# into the checkout leaves changes indistinguishable from a person's own edits, so review cannot
# catch them and nobody has a reason to look. Observed from out here because a suite cannot watch
# what it does to the repo itself.
#
# The copy inventory regeneration is the one run that is MEANT to rewrite a checked-in file, so it
# says the check is off rather than being quietly exempt from it (L65: a control skipped in silence
# is indistinguishable from a control that is gone).
TREE_SNAPSHOT="$(mktemp "${TMPDIR:-/tmp}/overture-tree-state.XXXXXX")"
trap 'rm -f "${TREE_SNAPSHOT}"' EXIT
if [[ -n "${TEST_RUNNER_REGENERATE_COPY_INVENTORY:-}" ]]; then
  echo "==> working-tree check OFF: this run regenerates the copy inventory on purpose"
  TREE_SNAPSHOT=""
else
  "${REPO_ROOT}/scripts/check-tree-untouched.sh" record "${REPO_ROOT}" "${TREE_SNAPSHOT}"
fi

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

# Warns when docs/prep-runbook.md has changed since the paid eval (scripts/eval-prep-runbook.sh --yes)
# last COMPLETED, so a drafting rule cannot ship with nothing having scored real model output against
# it (#1867). Never blocks: that eval spends tokens and is deliberately hand-run, so this reports and
# exits 0 whatever it finds, and skips cleanly on a machine that cannot run the eval at all.
echo "==> scripts/check-prep-eval-freshness.sh"
"${REPO_ROOT}/scripts/check-prep-eval-freshness.sh"

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

# Fails if the tracked .claude/settings.json stops disabling the Claude Code plugins that have no
# business loading in this repo (#2605). #1682 turned them off for the DETACHED runs only; this covers
# the interactive session, where the same plugin was measured injecting 53.2KB of another product's
# documentation into every session opened here.
echo "==> scripts/check-project-plugin-scope.sh"
"${REPO_ROOT}/scripts/check-project-plugin-scope.sh"

# The app launches its runners with /bin/sh, so they must PARSE there. `bash -n` is not enough and
# missing that shipped a runner that died on its first real run.
echo "==> scripts/check-runner-posix.sh"
"${REPO_ROOT}/scripts/check-runner-posix.sh"

# Lists every LIVE-STORE-CLAIM tag (a doc/comment count measured against Dan's live SwiftData store,
# e.g. "0 of 26 distinct venue strings contain a city") with its last-verified date, and warns
# (advisory only) on a stale one or a claim that looks measured but carries no tag at all (#1063). The
# #1060 fix caught one instance of exactly this by accident; three more copies of that same stale claim
# had survived untouched elsewhere in the repo until this issue's own sweep found them. Never depends on
# the live store itself (CI and any machine without it simply can't have that file), so it only fails on
# a genuinely malformed tag or a checked-in fixture that disagrees with its own claim.
echo "==> scripts/check-live-store-claims.sh"
"${REPO_ROOT}/scripts/check-live-store-claims.sh"

# Blocks a file in the pure Swift suite from importing the app as a module, which stops that target
# compiling so NOT ONE of its 4,800 tests runs. Deliberately ahead of the Swift run below: this is the
# one break a Swift guard cannot catch (an offender means no Swift test can execute at all), and naming
# the file here costs seconds instead of a full build ending in "unable to resolve module dependency".
echo "==> scripts/check-pure-suite-imports.sh"
"${REPO_ROOT}/scripts/check-pure-suite-imports.sh"

# Blocks a STALE committed mac/Overture.xcodeproj/project.pbxproj from reaching main (#1368). Compares it
# against a fresh xcodegen generate and BLOCKS on any difference; a xcodegen version mismatch says "cannot
# verify" rather than a false "stale". Local-only like the Swift suite below (CI has no xcodegen/Xcode).
echo "==> scripts/check-pbxproj-fresh.sh"
"${REPO_ROOT}/scripts/check-pbxproj-fresh.sh"

# #1970: clears LaunchServices registrations pointing at Overture bundles that no longer exist, and
# says how many it took out. Dan's call, 2026-08-04: "it should clear them without me."
#
# Only ever unregisters a path that is gone from disk, so an installed bundle can never be touched. It
# costs about 9ms per entry and nothing at all when there is nothing stale, which is the ordinary case
# once each build unregisters the bundle it replaces.
#
# Never blocking: a dirty LaunchServices database on this Mac is not a defect in the change being
# pushed, so a registrar that cannot be read must not stop the push. It is here because nothing counted
# this for years, and by the time anything noticed there were 86 of them for a single-instance app.
echo "==> mac/scripts/prune-stale-registrations.sh"
"${REPO_ROOT}/mac/scripts/prune-stale-registrations.sh" || true

# #2585: deletes the Xcode build folders belonging to worktrees that no longer exist, and says how much
# room is left. Xcode keys DerivedData by workspace PATH, so every throwaway verify worktree and every
# parallel agent mints a fresh ~1.6 GB folder outside the checkout that nothing reclaimed. On 2026-08-12
# that reached 148 GB and took the volume to 132 MiB free, at which point no command could run at all.
#
# Here, rather than in a script somebody has to remember, because the failure mode IS that nobody looks
# until the machine stops. Only ever removes a folder whose workspace is gone from disk, so it can never
# cost anyone a rebuild, and never blocking for the same reason as the line above: a Mac that will not
# let a folder be deleted is not a defect in the change being pushed.
echo "==> scripts/reclaim-orphan-derived-data.sh"
"${REPO_ROOT}/scripts/reclaim-orphan-derived-data.sh" || true

echo "==> mac/scripts/run-tests-locked.sh"
"${REPO_ROOT}/mac/scripts/run-tests-locked.sh"

if [[ -n "${TREE_SNAPSHOT}" ]]; then
  echo "==> scripts/check-tree-untouched.sh"
  "${REPO_ROOT}/scripts/check-tree-untouched.sh" compare "${REPO_ROOT}" "${TREE_SNAPSHOT}"
fi

echo "==> all suites passed"
