# Overture

Overture finds performing arts performances worth pitching for Dan Wright Photography,
ranks them by fit, and surfaces them for Dan to review, keep, and (later) approve a
drafted email. See `PLAN.md` for the full product plan.

This repository holds two pieces:

- **The native macOS app** (`mac/`): a SwiftUI app (the review surface Dan lives in),
  generated with `xcodegen` from `mac/project.yml`. It owns a local SwiftData store and
  runs the whole scout itself, extract, classify, match, rank, assemble, upsert, no
  TypeScript involved. Mirrors Downbeat's structure and conventions; keeps Overture's
  own forest-green and gold brand.
- **The booking-history importer** (`src/lib/`, `scripts/`): a small TypeScript script,
  run with `tsx` and tested with `vitest`, that one-shot imports the Downbeat booking
  history CSV into `overture-history.json` for the app to read. The agentic
  scouting/contact-finding/drafting runs as a Claude Code workflow on Dan's Max plan.

The earlier Next.js web dashboard was retired once Dan chose a native Mac app. A parallel
TypeScript scout/classify/rank/assemble pipeline that used to mirror the native app's own logic
was retired in #493 once it was confirmed unused (the real scout has always run natively) and
already drifting from the Swift version it mirrored.

## Working here

- Before pushing anything that touches a cross-language contract (`fixtures/`,
  `docs/contracts.md`), or really before pushing anything at all, run `scripts/test-all.sh`
  from the repo root. It runs `pnpm typecheck`, `pnpm test`, and the Swift suite in one
  command (#595). This matters even more since #1347: CI no longer runs the Swift tests at
  all (only `typecheck-and-test`, on GitHub-hosted ubuntu-latest), so a local run is the ONLY
  thing that verifies the Mac app before it reaches main. The mandatory local pre-push gate
  already runs the full Mac suite, but `test-all.sh` also catches a TypeScript-side failure
  that CI would otherwise only surface minutes later.
- Importer: `pnpm test`, `pnpm typecheck`, `pnpm import-history <csv-path>` (one-shot booking
  history import, see `docs/import-history.md`). The scout itself is entirely native; see
  `docs/scout-runbook.md`.
- Mac app: `cd mac && xcodegen generate`, then `./scripts/run-tests-locked.sh` (wraps
  `xcodebuild -scheme Overture -destination 'platform=macOS' test` in a lock so it can't
  collide with another test run on this Mac; use it instead of raw `xcodebuild test`). A
  scoped `-only-testing:OvertureTests/<Suite>/<test>` run can print
  `** TEST SUCCEEDED **` with 0 tests executed if the path doesn't match anything (for
  example a `@Suite("...")` display name that differs from its Swift type name),
  indistinguishable at a glance from a real pass. Confirm a scoped run by grepping its
  output for the specific test name, or just run the full suite via
  `run-tests-locked.sh`, which completes in a few seconds.
- To actually LOOK at the app, use `mac/scripts/run-debug.sh` (#567): it regenerates the
  project, quits any Debug instance still running (a stale one silently holds the Debug store's
  single-writer lock, so a fresh launch comes up in the degraded "another copy is using its data"
  state and the change under test looks broken), builds Debug, verifies the built bundle really
  carries the Debug identity, and only then launches it, printing the exact `.app` path and the
  store it will touch. It refuses to launch a bundle claiming the Release identity, which would
  open the LIVE store. Release has its own installer, `mac/build-install.sh`.
- Changing what the app SAYS: `docs/copy-inventory.md` is every sentence Overture can say to Dan
  (#915), generated from the source and checked in. The test suite regenerates it and fails when it
  is stale, so a PR that changes the app's wording shows that change in the diff, in the words Dan
  will read rather than as a line of Swift. If a run fails saying the inventory was out of date, it
  has already rewritten the file: read `git diff docs/copy-inventory.md`, and if it says what you
  meant, commit it. Copy that is NOT the app's own voice (an outbound email body, an RFC822 header,
  AppleScript, the draft lint's search terms) is marked at the source with
  `// copy-inventory:ignore-start  <why>`, and every such region is listed in the inventory itself.
  Before opening a PR that adds or changes any of these sentences, read the new and changed ones
  COLD (#843/#844): open `git diff docs/copy-inventory.md`, read each added or reworded line in the
  order a person meets it on screen (the row title before its subtitle, the section heading before
  its body, the pill name before its detail, the concept summary before the live line shown beside
  it), with no memory of why the code produces it, and ask of each: does this tell Dan anything the
  line next to it did not? If not, cut it, or show the second line only in the edge case where the
  two genuinely differ. The whole class of defect (#840, #841, the third in #840's comment, and the
  nine #843 fixed) is invisible from inside the code and obvious the instant a person reads the
  screen, and no test can catch any of it; this cold read is the only thing that does, so it is a
  required step, not a good intention. A distinction that is real in the code ("checked" versus
  "read", #803) still collapses to the same sentence twice in the common case, which is exactly what
  the read has to catch.
- Changing the AI drafting instructions: those rules live in two places that must stay in sync,
  `docs/prep-runbook.md` §2 inside this repo and the `dan-wright-brand-voice` skill at
  `~/.claude/skills/dan-wright-brand-voice/` (which is NOT tracked by this repo, and is the
  authoritative source, "the skill always wins"). `scripts/check-brand-voice-drift.sh` (#731) warns
  when the two drift apart on the concrete facts they both state (the citable credentials, marquee
  venues, portfolio link, the four opener shapes, the soft close). It rides along in
  `scripts/test-all.sh`, and skips cleanly on any machine without the skill installed, so edit a
  drafting rule in one place and a local pre-push run flags the other side going stale.
- Regression harness for the runbook's JUDGMENT (#591). The runbook is a prompt, not code, so a rule
  it encodes (never the host venue, never a press inbox, both named performers, strict confidence) can
  be silently broken by an unrelated edit. Two layers guard it. The ALWAYS-ON free layer runs on every
  `pnpm test`: `src/lib/prepRunbookRules.test.ts` asserts each guarded rule stays in the runbook text,
  and `src/lib/prepEval.test.ts` scores recorded outputs against `fixtures/prep-eval/` expectations. The
  OPT-IN real-AI layer, `scripts/eval-prep-runbook.sh --yes`, runs the CURRENT runbook against those
  fixtures through the same headless `claude -p` mechanism as `prep-run.sh` and scores each real output
  with the SAME engine (`src/lib/prepEval.ts`). It SPENDS TOKENS and is wired into no CI job: run it by
  hand before shipping a runbook edit. See `fixtures/prep-eval/README.md`.
- Running multiple Claude agents on this repo at once: give each agent its own git
  worktree so file edits and branches never collide, but xcodebuild itself must stay
  serialized across all of them. `run-tests-locked.sh`'s lock file lives at one fixed
  path outside any checkout, so every worktree contends for the same lock instead of
  each locking its own copy (since #1347 there is no longer a CI run contending for it;
  the Swift tests run only locally). The current verification model is a hybrid:
  each agent builds and tests its own worktree under that shared lock and stops after
  opening a PR (it never merges and never launches the live app); the coordinating
  session then independently re-runs the full suite on every branch under the same
  lock before merging, rather than trusting each agent's self report.

The pieces hand off through fixed-shape JSON files, not direct calls. `docs/contracts.md`
catalogs every one (writer, reader, version, and its `fixtures/` guard); read it before changing
any cross-boundary file shape.

## Restoring Overture from a backup

The live SwiftData store (every prospect, contact, and outreach record) lives at
`~/Library/Application Support/default.store` for the Release build, or
`~/Library/Application Support/Overture-Debug/default.store` for a Debug run. It is NOT at
`~/Library/Application Support/Overture/default.store`: that legacy path predates the
#264/#267 Debug/Release split and isn't used by the current app, since `Overture/` today only
holds the JSON handoff files, never the store.

As of #601/#602, every launch first copies the store into a dated subfolder under
`overture-store-backups/` next to the live one (for example
`~/Library/Application Support/overture-store-backups/20260706-101800/`), keeping the last 10.
Each backup's outcome is logged to `overture-store-backups/backup.log`. Separately, a handful of
older, ONE-OFF manual backups made by hand before risky migrations already sit loose directly in
`~/Library/Application Support/` (for example `overture-store-backup-20260628-*/`,
`default.store.phasef-backup-*`, `default.store.435-backup-*`); those predate the automatic
mechanism and aren't rotated or pruned, so check their timestamps if a launch-time backup isn't
recent enough.

To restore: quit Overture (including from the menu bar), copy the desired backup's
`default.store` (+ `-wal`/`-shm`, if present) over the live files at the path above, then
relaunch.

As of #663, launch also refuses to open a file at that path that doesn't already contain
Overture's own `ZPROSPECT` table (checked read-only, before anything else touches the file). This
catches another app writing its own database to the same shared, unsandboxed path (it happened
once with Downbeat, 2026-07-08): instead of CoreData silently creating a fresh, near-empty store
inside the foreign file, Overture shows the store-unavailable screen with a reason naming the
path, so the collision is caught at launch instead of requiring a manual sqlite3 inspection to
even notice.

## CI status before merging

Since #1347 the ONLY CI check is `typecheck-and-test` (the TypeScript importer, on
GitHub-hosted ubuntu-latest). The Swift tests no longer run in CI: they were on a
self-hosted runner on Dan's Mac that kept going offline mid-job and stalling every merge,
so they were retired in favour of the mandatory local pre-push gate (which runs the full
Mac suite before any push). This means a merge's Swift verification comes from having run
`mac/scripts/run-tests-locked.sh` (or `scripts/test-all.sh`) locally and SEEN it pass, not
from CI. Do not merge a Swift change without that local pass in hand.

The committed `mac/Overture.xcodeproj/project.pbxproj` is generated by xcodegen (see
`docs/contracts.md`), and nothing in CI checks it. `scripts/check-pbxproj-fresh.sh` (#1368) is that
gate: it compares the committed pbxproj against a fresh `xcodegen generate` and BLOCKS on any drift
(a xcodegen version other than `XCODEGEN_PINNED_VERSION` in `scripts/ci-config.sh` says "cannot
verify" rather than a false "stale"). It rides along inside `scripts/test-all.sh`, and both merge
scripts run it: `verify-and-merge-branch.sh` checks BEFORE its worktree regen (the old blind
pre-`xcodegen generate` used to silently rebuild a stale file and ship it), and
`merge-when-green.sh` fetches the branch and checks only when the PR touches the Mac app. The one
path this does NOT structurally cover is a bare `gh pr merge` (the `next-issue` shortcut): a merge
that touches the Mac project MUST go through `scripts/test-all.sh` (then `merge-when-green.sh`) or
`scripts/verify-and-merge-branch.sh`, never a bare `gh pr merge`, or a stale pbxproj can still reach
main.

For the one remaining check, a pending run and a stuck one still look identical in GitHub's
PR view, so do not merge on "it hasn't failed yet". `scripts/check-pr-ci.sh <pr-number>`
reports every check's real state, and `scripts/merge-when-green.sh <pr-number>` polls and
merges only once it reports a genuine pass (stopping on a real failure or its own timeout).
Both still work. #1352 removed their self-hosted-runner stall detection (dead since #1347
retired the runner) along with the runner scripts, launchd plist, and setup doc; a pending
GitHub-hosted check now just reads as "Pending", which blocks the merge, and there is no
runner left that could silently swallow a job forever. The `overture-mac` self-hosted runner
itself may still be left registered-but-idle on GitHub, and unloading its launchd agent
(`com.danwright.overture.ci-runner`) on Dan's Mac is a separate manual cleanup (the plist is
gone from the repo, so the tear-down is `launchctl bootout gui/$(id -u)/com.danwright.overture.ci-runner`
plus removing `~/Library/LaunchAgents/com.danwright.overture.ci-runner.plist` if present).
