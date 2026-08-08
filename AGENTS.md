# Overture

Overture finds performing arts performances worth pitching for Dan Wright Photography,
ranks them by fit, and surfaces them for Dan to review, keep, and (later) approve a
drafted email. See `PLAN.md` for the full product plan.

It also tracks the traffic going the other way: a direct hire inquiry (someone reaching out
to hire Dan through his contact form or by email) is logged by hand and rides the SAME daily
queue, stages, reply detection, and booking match as a scouted show, so both halves of the
funnel live on one surface instead of splitting his attention with his inbox. Inquiries are a
fully separate entity from scouted prospects with no relationship between them, never linked
or merged even when they reference the same show, and they deliberately bypass the queue's
lead-time date window: an inquiry is live because someone is waiting on a reply, whatever the
event date. Milestone #31 (issues #1434 to #1438) built it; #16 is the intended home for
reporting on the outcomes it captures.

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
  judges that each change carries a test (and enforces the style rules); it does NOT itself run
  the suites, so `test-all.sh` is what actually runs the full Mac suite plus the TypeScript side
  that CI would otherwise only surface minutes later. Run it before every push.
- One-time per clone: run `scripts/install-git-hooks.sh` once in each clone/worktree (#1251
  Phase 3). It points git at `scripts/hooks`, whose `post-merge` hook regenerates a stale
  `mac/Overture.xcodeproj/project.pbxproj` after a merge that combined Mac source changes and
  stages it for you to commit. It is only a convenience (it cannot fire after a conflicted merge
  finished by a manual commit); `scripts/check-pbxproj-fresh.sh` remains the real gate.
- Keeping the checkout tidy: `scripts/tidy-checkout.sh` (#2234) removes local branches and agent
  worktrees whose work has provably shipped. It is a DRY RUN by default and needs `--apply` to
  delete anything. Note WHY it exists rather than the one-line idiom: this repo squash-merges, so a
  shipped branch is never an ancestor of main and `git branch --merged main -d` recognises almost
  none of them (39 of 496, measured 2026-08-06). It proves containment by a merged PR or by
  `git cherry`, keeps anything with an open PR, anything a worktree has checked out, and any
  worktree holding uncommitted work, and answers every unanswerable question in the keep direction.
  From #2234 both merge scripts also delete the local branch they just merged, since
  `gh pr merge --delete-branch` only removes it on GitHub, which is where the backlog came from.
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
  `run-tests-locked.sh`, which takes about a minute and a half.
- Since #1967 the Swift tests live in TWO targets, and which one a new test belongs in is decided
  by one question: does it need the app RUNNING?
  - `OvertureTests` (4,802 tests, `mac/OvertureTests/`) is the default and where a new test goes
    unless it renders a view. It is UNHOSTED: it reaches the app's code by compiling it in, not by
    linking a host, so it has no `TEST_HOST` and no dependency on the app target at all.
  - `OvertureHostedTests` (162 tests, `mac/OvertureHostedTests/`) is only the ViewInspector ones,
    which render a real SwiftUI view and so genuinely need the host process.
  - `mac/TestSupport/` holds the helpers both compile (`SourceGuardHelper`, `SwiftSource`,
    `CopyInventory`), in one place so a guard helper cannot drift between the two targets.
  This exists because every test used to run inside the launched app, so one launch fault took all
  of them: on 2026-08-01 a crowded menu bar removed the status item, which terminates a
  `MenuBarExtra` app, and nothing in the Mac app could be verified at all. Measured 2026-08-02 with
  a deliberate `fatalError()` in `OvertureApp.init`: the pure suite reported
  `Test run with 4802 tests in 690 suites passed`, `** TEST SUCCEEDED **`, exit 0, while the app
  could not start.
- The pure suite has its own scheme, `OvertureCore`, which does NOT build the app. Use it
  (`xcodebuild -scheme OvertureCore -destination 'platform=macOS' test`) to verify domain logic while
  the app is broken or mid-refactor; it does not even need the app to compile. This matters because
  `-only-testing:OvertureTests` on the combined `Overture` scheme does NOT avoid the app: xcodebuild
  still prepares and launches the host, and a crash there decided the exit code even though all 4,802
  passed. `run-tests-locked.sh` now falls back to this scheme automatically whenever a run CRASHES, so
  a dead host reports "the PURE suite PASSED, the failure above is the APP HOST, not your code"
  instead of one undifferentiated red. `PureSchemeExcludesTheAppTests` fails if the app is ever put
  back into that scheme.
- To actually LOOK at the app, use `mac/scripts/run-debug.sh` (#567): it regenerates the
  project, quits any Debug instance still running (a stale one silently holds the Debug store's
  single-writer lock, so a fresh launch comes up in the degraded "another copy is using its data"
  state and the change under test looks broken), builds Debug, verifies the built bundle really
  carries the Debug identity, and only then launches it, printing the exact `.app` path and the
  store it will touch. It refuses to launch a bundle claiming the Release identity, which would
  open the LIVE store. Release has its own installer, `mac/build-install.sh`. That installer signs the
  bundle with a stable local identity so macOS keeps its TCC grants (calendar, Gmail/automation,
  reminders) across reinstalls instead of dropping them, which an ad-hoc signature silently did because
  its cdhash changes every rebuild (#1425). Run `mac/scripts/setup-signing-identity.sh` ONCE per Mac
  first (it creates and trusts a dedicated "Overture Local Signing" certificate, the one manual step is
  a trust-settings password dialog); after that every build signs automatically. `build-install.sh`
  fails loud if that identity is missing rather than falling back to ad-hoc. The one-time switch to this
  identity re-prompts for permissions on the first install after it, then they persist.
- `build-install.sh` builds WHATEVER IS CHECKED OUT, which is what you want when installing a branch build
  deliberately. The freshness panel's Update button does NOT run it directly: it runs
  `mac/scripts/update-overture.sh`, which brings the checkout up to origin/main first and only then
  installs, refusing (and installing nothing) when it cannot do that safely, e.g. uncommitted work in the
  tree or a local main holding commits the remote does not. Pressing Update means "get me what has
  shipped"; running the installer by hand means "build this". They were the same command until 2026-08-04,
  and Dan hit the loop that follows from it: the panel compares the installed commit against origin/main,
  so a checkout parked on an already-merged branch reinstalled the same commit and stayed behind forever.
  A corollary for anyone working here: leave the checkout on main when you finish, because a session that
  parks it on a branch is what puts the Update button in front of that state.
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
  Read the OTHER generated diff in the same pass: `docs/copy-surfaces.md` (#2210) says which surfaces
  each file renders into, so the cold read answers where a new sentence LANDS as well as what it says.
  A message in a toolbar item, a menu bar item, an OS alert or an info block can be correct, tested,
  and still fail to do its job (the platform relocates or covers it, or it arrives somewhere Dan
  cannot act on it), and that report names those four surfaces and why each one is a risk. Three of
  the eight defects found on 2026-08-06 were exactly that shape and none was visible in the sentence
  alone.
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
`~/Library/Application Support/Overture/Overture.store` for the Release build, or
`~/Library/Application Support/Overture-Debug/Overture.store` for a Debug run. In Release the store
sits in the SAME folder as the JSON handoff files, deliberately: that folder's path is a published
contract (`docs/contracts.md`, the runbooks, `import-history.ts`, `runner-setup.sh`), so putting the
store there moved it off the shared root without changing a single documented path.

It did NOT always live there. Until the store-path move it sat directly in the Application Support
ROOT as `default.store`, which is what SwiftData names a store when the app doesn't say otherwise.
Both halves of that were defaults nobody chose, and both are shared by every unsandboxed SwiftData
app on the Mac. It cost Dan his live store twice: Downbeat opened it on 2026-07-08, and on
2026-07-23 `/usr/libexec/icloudmailagent` ran a Core Data lightweight migration onto it and replaced
every Overture table with its own single `ZAPIREQUESTMODEL`. Do not move the store back toward
either default. `StoreLocation` owns both the folder and the filename; `StoreRelocation` performs
the one-time move at launch and refuses to carry a file that isn't Overture's.

As of #601/#602, every launch first copies the store into a dated subfolder under
`overture-store-backups/` next to the live one (for example
`~/Library/Application Support/Overture/overture-store-backups/20260706-101800/`), keeping the
last 10. Each backup's outcome is logged to `overture-store-backups/backup.log`.

A folder whose name ends in `.foreign` (for example `20260723-113732.foreign`) is NOT a backup of
Dan's data and must never be restored from (#1410). It is the snapshot the #663 guard takes of
whatever file it found at the store path before refusing to open it, kept as evidence: the one on
2026-07-23 holds icloudmailagent's database. Its log line says so, and it is deliberately outside the
plain `yyyyMMdd-HHmmss` shape that rotation counts and deletes, so a run of refusals can never age
out the ten real backups. `backup.log` also now distinguishes a launch whose copy failed outright, or
copied only some of the store's files, from a clean `success`.

Backups made BEFORE the store-path move are a frozen archive at the OLD location,
`~/Library/Application Support/overture-store-backups/`, and hold a file named `default.store`
rather than `Overture.store`. Nothing rotates or prunes them any more, which is a useful property
(that history can no longer be aged out), but it means a restore from one of those is a rename on
the way in. Separately, a handful of older ONE-OFF manual backups made by hand before risky
migrations sit loose directly in `~/Library/Application Support/` (for example
`overture-store-backup-20260628-*/`, `default.store.phasef-backup-*`, `default.store.435-backup-*`).

To restore: quit Overture (including from the menu bar), copy the desired backup's store file
(+ `-wal`/`-shm`, if present) over the live files at the path above, renaming `default.store` to
`Overture.store` if the backup predates the move, then relaunch.

As of #663, launch also refuses to open a file at that path that doesn't already contain
Overture's own `ZPROSPECT` table (checked read-only, before anything else touches the file). This
is what caught BOTH collisions above: instead of CoreData silently creating a fresh, near-empty
store inside the foreign file, Overture shows the store-unavailable screen with a reason naming the
path. The same check gates the one-time move, so a foreign file left at the old path is never
carried onto the new one. The folder move makes the collision impossible in the first place; the
guard remains the net under it.

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
