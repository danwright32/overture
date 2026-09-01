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
# #2603: TWO LANES. The Swift suite is the dominant cost by minutes, and its opening seconds go on
# waiting for the shared xcodebuild lock and then building, during which nothing else here is doing
# anything. So it starts FIRST, in the background, and the cheap checks run beside it. The plumbing and
# the reporting rules live in scripts/lib/test-all-phases.sh, which has its own fixture; what matters
# when reading this file is that a cheap failure no longer ends the run, because the expensive lane is
# already going and its verdict is worth having. Both verdicts are reported separately at the end and
# the exit code is red if either lane is red (L53).
#
# Usage: scripts/test-all.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

# shellcheck source=./lib/test-all-phases.sh
source "${REPO_ROOT}/scripts/lib/test-all-phases.sh"

# #3168: install the TypeScript dependencies HERE, before the snapshot below, because this is a step
# the run is defined to perform rather than something it leaves behind.
#
# pnpm installs missing dependencies by itself the first time a script is run, so until this existed the
# install happened inside `pnpm typecheck` in the cheap lane, minutes after the snapshot was taken. On any
# checkout without `node_modules` the ignored half of the tree check then reported `appeared: node_modules/`,
# every time. That is guaranteed rather than incidental on the path that matters most:
# verify-and-merge-branch.sh scrubs its verify slot with `git clean -ffdx`, which removes `node_modules`,
# so every verify-and-merge and verify-and-merge-batch run reported it, starting with the very first one.
# A report that speaks on every merge is one people learn to scroll past, and then the stray state file it
# exists to surface goes unread too (L36, L93).
#
# Ordering rather than an exception list naming `node_modules`, which would be a hand-written registry and
# would go stale the way any registry-driven guard does (L96). What it gives up is the window before the
# install: a stray written in it is now inside the snapshot rather than after it. That window holds nothing
# but this line.
#
# It does NOT take the run down on its own. Neither lane has started yet, so a failure here under `set -e`
# would end the run before anything reported; `pnpm typecheck` and `pnpm test` in the cheap lane report a
# broken install exactly as they did before this step existed.
echo "==> pnpm install"
pnpm install || echo "FAILED - pnpm install (the pnpm checks in the cheap lane below report what is broken)"

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

# --- before the build, and fail-fast, deliberately ------------------------------------------------
#
# These two cannot move into the lane beside the Swift suite, and each for its own reason.
#
# check-pure-suite-imports.sh is the one break a Swift guard cannot catch: a file in the pure suite
# importing the app as a module stops that target compiling, so NOT ONE of its tests runs. Naming the
# file here costs seconds; letting the build start first would cost the whole build and end in "unable
# to resolve module dependency". That saving only exists if it runs first.
echo "==> scripts/check-pure-suite-imports.sh"
"${REPO_ROOT}/scripts/check-pure-suite-imports.sh"

# check-pbxproj-fresh.sh does its own xcodegen regen-and-restore inside this checkout, so it must not
# run WHILE xcodebuild is reading the same project file. It is also the check that decides whether the
# thing about to be built is even the right project, which is not worth building against if stale.
echo "==> scripts/check-pbxproj-fresh.sh"
"${REPO_ROOT}/scripts/check-pbxproj-fresh.sh"

# --- the expensive lane starts here ---------------------------------------------------------------
SWIFT_LABEL="mac/scripts/run-tests-locked.sh"
SWIFT_LOG="$(mktemp "${TMPDIR:-/tmp}/overture-swift-suite.XXXXXX")"
echo "==> ${SWIFT_LABEL} (started in the background; its output streams below once the cheap checks are done)"
start_background_phase "${SWIFT_LOG}" "${REPO_ROOT}/mac/scripts/run-tests-locked.sh"
SWIFT_PID="${BACKGROUND_PHASE_PID}"
SWIFT_STATUS_FILE="${BACKGROUND_PHASE_STATUS_FILE}"

# However this script leaves, the suite it started goes with it. An orphaned xcodebuild would hold the
# shared lock and keep every other worktree's run queued behind a run nobody is reading.
# #3105: stopped through the helper, which reaps the job as well as killing it. A bare kill leaves the
# shell to announce the job at the next command boundary, and that notice renders the job's whole body
# into this run's own output.
trap 'stop_background_phase "${SWIFT_PID}"; rm -f "${TREE_SNAPSHOT}" "${SWIFT_LOG}" "${SWIFT_STATUS_FILE}"' EXIT

# Nothing in the cheap lane touches the Swift build. Audited 2026-08-13: the shell fixtures stub
# xcodebuild and flock inside their own mktemp PATH dirs (so none reaches the real lock), no fixture
# kills a process by pattern, and the drift checks are read-only. The two that mutate anything outside
# the checkout (LaunchServices registrations, orphaned DerivedData folders) only ever touch entries
# whose target no longer exists.

# --- the cheap lane, beside it --------------------------------------------------------------------
TEST_ALL_CHEAP_FAILURES=()

run_foreground_check "pnpm typecheck" pnpm typecheck
run_foreground_check "pnpm test" pnpm test
run_foreground_check "scripts/run-shell-fixtures.sh" "${REPO_ROOT}/scripts/run-shell-fixtures.sh"

# #2726: fails when a source-text guard searches a WHOLE FILE for text that occurs in it more than once,
# so the guard can be answered by an occurrence it is not about. Roughly 1,900 of this suite's
# declarations are source-text guards and CAUGHT is the verdict quoted as proof of each, so a guard that
# cannot go red is the most expensive kind of green there is (L135). #2773 shipped the tool and nothing
# ran it, and 17 entries had accumulated by 2026-08-21; all 17 were answered, so zero is reachable and
# this keeps it there. A new entrant is a test to LOOK AT, not automatically a defect, and the remedy is
# one line either way: name the occurrence instead of searching the file.
# ADVISORY, never blocking, on the same footing as check-branch-backlog.sh below. Dan's standing rule is
# that he wants the override on anything, with the reason named in the message, and a check nobody can
# get past on his own machine is the shape he has asked not to have. It was written as a hard gate first;
# this is the correction.
#
# What it gives up is real and is why the number is printed either way: nothing now STOPS the list growing
# back, which is how 17 accumulated after #2773 shipped the tool with nothing running it. What it keeps is
# that the list is in front of somebody on every single run rather than in a command nobody types, and the
# remedy is one line. Set OVERTURE_VACUOUS_GUARDS_STRICT=1 to have it fail the run instead.
echo "==> pnpm find-vacuous-guards"
if pnpm find-vacuous-guards; then
  :
elif [ "${OVERTURE_VACUOUS_GUARDS_STRICT:-0}" = "1" ]; then
  TEST_ALL_CHEAP_FAILURES+=("pnpm find-vacuous-guards")
  echo "FAILED - pnpm find-vacuous-guards (OVERTURE_VACUOUS_GUARDS_STRICT=1)"
else
  echo "  Advisory, so this does NOT fail the run. Each one is a source-text guard that can be answered by"
  echo "  an occurrence it is not about, so it may be green while protecting nothing (L135). The fix is to"
  echo "  name the site instead of searching the whole file. Re-run with OVERTURE_VACUOUS_GUARDS_STRICT=1"
  echo "  to make it blocking."
fi

# #3270: stored process-wide statics in the test targets that nobody has accounted for. Each one is a
# single variable shared by every test in the process, so once parallel testing is on it is a test that
# fails once in four runs rather than reliably, which is the shape that trains people to re-run until
# green. Four were found in #3234 by running the suite in parallel four times and reading the wreckage,
# a full run per round; a fifth was found by hand in seconds by listing the mutable statics. This is
# that listing, kept.
#
# ADVISORY, never blocking, on the same footing as pnpm find-vacuous-guards above and
# check-branch-backlog.sh below: a new stored static is not automatically a defect, and Dan's standing
# rule is that he wants an override on anything, with the reason named in the message. It rides along
# here rather than sitting behind a command nobody types, which is what #2773 cost: the tool shipped,
# nothing ran it, and 17 entries had accumulated by the time anybody looked. It is one grep.
#
# Exit 2 is UNMEASURED and is NOT folded into the advisory: a run that read no Swift at all says nothing
# about the tree, and the emptiest possible failure must not read as the cleanest possible pass (L98).
echo "==> scripts/check-test-shared-state.sh"
SHARED_STATE_STATUS=0
"${REPO_ROOT}/scripts/check-test-shared-state.sh" || SHARED_STATE_STATUS=$?
if [ "${SHARED_STATE_STATUS}" = "2" ]; then
  TEST_ALL_CHEAP_FAILURES+=("scripts/check-test-shared-state.sh")
  echo "FAILED - scripts/check-test-shared-state.sh could not measure anything (exit 2)"
elif [ "${SHARED_STATE_STATUS}" != "0" ]; then
  echo "  Advisory, so this does NOT fail the run. Give the suites that touch it a shared lock"
  echo "  (mac/OvertureTests/SharedStateTestLock.swift), or record why it cannot collide with"
  echo "  scripts/check-test-shared-state.sh --record."
fi

# #3386: how much of the Swift suite runs on the main actor, which is one serial executor and therefore
# the length of the queue every main-actor test waits in under parallel testing. Before this nobody could
# say how big it was, and the reduction it asks for has no number to be measured against.
#
# ADVISORY and never a gate, on the same footing as the two above: 300 of the 462 files carrying the
# attribute touch SwiftData, whose containers are main-actor bound, so a rule refusing a new one would
# fire on the ordinary case and be switched off within a day (L93). Exit 2 is UNMEASURED and is not
# folded into it, for the reason the shared-state check states.
echo "==> scripts/check-main-actor-share.sh"
MAIN_ACTOR_STATUS=0
"${REPO_ROOT}/scripts/check-main-actor-share.sh" || MAIN_ACTOR_STATUS=$?
if [ "${MAIN_ACTOR_STATUS}" = "2" ]; then
  TEST_ALL_CHEAP_FAILURES+=("scripts/check-main-actor-share.sh")
  echo "FAILED - scripts/check-main-actor-share.sh could not measure anything (exit 2)"
fi

# Warns if docs/prep-runbook.md and the external dan-wright-brand-voice skill have drifted apart
# (#731). Skips cleanly (exit 0) on any machine without the skill installed, since it lives outside
# this clone, so it never breaks CI or a fresh checkout; it only fails locally on genuine drift.
run_foreground_check "scripts/check-brand-voice-drift.sh" "${REPO_ROOT}/scripts/check-brand-voice-drift.sh"

# Warns when docs/prep-runbook.md has changed since the paid eval (scripts/eval-prep-runbook.sh --yes)
# last COMPLETED, so a drafting rule cannot ship with nothing having scored real model output against
# it (#1867). Never blocks: that eval spends tokens and is deliberately hand-run, so this reports and
# exits 0 whatever it finds, and skips cleanly on a machine that cannot run the eval at all.
run_foreground_check "scripts/check-prep-eval-freshness.sh" "${REPO_ROOT}/scripts/check-prep-eval-freshness.sh"

# Fails if a second near-copy source-health recorder has been reintroduced in the scout ingest files
# (#1073). The #987/#1001/#1005 defect (two recorders drifting until one silently stops writing a
# field) is caught at push time instead of in production.
run_foreground_check "scripts/check-health-recorder-drift.sh" "${REPO_ROOT}/scripts/check-health-recorder-drift.sh"

# Fails if any detached "$CLAUDE" -p runner under mac/scripts hardcodes a literal --allowedTools
# instead of folding through a *_claude_scope function in mac/scripts/lib/claude-run-scope.sh (#1102).
# Guards against a FUTURE fourth runner reintroducing the bare --allowedTools hole #1026/#1097 already
# closed for scout-extract, prep and reply-classify.
run_foreground_check "scripts/check-detached-runner-scope.sh" "${REPO_ROOT}/scripts/check-detached-runner-scope.sh"

# Fails if the tracked .claude/settings.json stops disabling the Claude Code plugins that have no
# business loading in this repo (#2605). #1682 turned them off for the DETACHED runs only; this covers
# the interactive session, where one was measured injecting 53.2KB of another product's documentation
# into every session opened here.
run_foreground_check "scripts/check-project-plugin-scope.sh" "${REPO_ROOT}/scripts/check-project-plugin-scope.sh"

# The app launches its runners with /bin/sh, so they must PARSE there. `bash -n` is not enough and
# missing that shipped a runner that died on its first real run.
run_foreground_check "scripts/check-runner-posix.sh" "${REPO_ROOT}/scripts/check-runner-posix.sh"

# Lists every LIVE-STORE-CLAIM tag (a doc/comment count measured against Dan's live SwiftData store,
# e.g. "0 of 26 distinct venue strings contain a city") with its last-verified date, and warns
# (advisory only) on a stale one or a claim that looks measured but carries no tag at all (#1063). The
# #1060 fix caught one instance of exactly this by accident; three more copies of that same stale claim
# had survived untouched elsewhere in the repo until this issue's own sweep found them. Never depends on
# the live store itself (CI and any machine without it simply can't have that file), so it only fails on
# a genuinely malformed tag or a checked-in fixture that disagrees with its own claim.
run_foreground_check "scripts/check-live-store-claims.sh" "${REPO_ROOT}/scripts/check-live-store-claims.sh"

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

# #2302: says when this checkout has silently filled up with local branches again, and nothing at all
# when it has not. Advisory only and structurally unable to fail a run (the script always exits 0, and
# the `|| true` is belt and braces), for the same reason as the line above: a cluttered checkout is not
# a defect in the change being pushed.
#
# Here rather than in a script somebody has to remember, because the failure mode IS that nobody
# counts: the 496 that #2234 cleared accumulated because nothing ever did, and the merge scripts it
# fixed cover only the paths that are a merge script.
echo "==> scripts/check-branch-backlog.sh"
"${REPO_ROOT}/scripts/check-branch-backlog.sh" || true

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

# --- back to the expensive lane -------------------------------------------------------------------
echo
echo "==> ${SWIFT_LABEL} (streaming from its first line)"
SWIFT_STATUS=0
stream_and_wait "${SWIFT_LOG}" "${SWIFT_PID}" "${SWIFT_STATUS_FILE}" || SWIFT_STATUS=$?

if [[ -n "${TREE_SNAPSHOT}" ]]; then
  run_foreground_check "scripts/check-tree-untouched.sh" \
    "${REPO_ROOT}/scripts/check-tree-untouched.sh" compare "${REPO_ROOT}" "${TREE_SNAPSHOT}"
fi

report_phase_results "${SWIFT_LABEL}" "${SWIFT_STATUS}"
