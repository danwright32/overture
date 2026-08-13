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

- **Before opening any PR, enumerate these four in the PR body. Not "checked": the actual list.**
  This exists because on 2026-08-10 two defects shipped from this repo and were filed as new issues
  within hours of the change that introduced them, both catchable in that same change. The rules were
  already written down; what was missing was being made to list the answers before the PR opened.
  1. **Every new value has a writer.** List every enum case, stored field, status, flag and category
     the change adds or extends, and name the code path that WRITES each one. Anything nothing writes
     is deleted or carries the number of the issue that activates it. All of them, not most: #2453
     named an activating issue for two of its three unwritten cases and the third became #2490. A
     category whose only input is a value nothing produces reads as zero, and zero is indistinguishable
     from a real measurement (L90, L65).
  2. **Every new value has a reader**, and where two sources could answer one question, which wins.
     A field written and never read looks alive to any is-this-used check while the purpose it was
     added for silently never happens (L46, L83).
  3. **The class, not the instance.** Enumerate the SIBLINGS of whatever was fixed: the other fields,
     tables, adapters or entities where the identical defect can occur. Cover each, or state why not
     with a filed issue number. #2478 scoped one out and it became #2495 the same evening. Derive the
     list from the code where that is possible, because a hand-written one only ever checks what
     somebody remembered (L30, L96).
  4. **Every guard was seen to fail.** Per guard: the exact mutation made, the exact failure text seen,
     and confirmation it was reverted (L1).

  A gap named in the PR body is fine. An unnamed one is the defect.

  The check that enforces this matches four WORDS literally, `writer`, `reader`, `sibling` and `seen`,
  so write the enumeration using them. It cannot read an answer, only find a word: PR #2526 answered
  the first question in full under the heading "the code path that WRITES it" and was refused for
  never saying "writer". Kept strict on purpose rather than accepting stems, because a looser match
  would let an incidental mention anywhere in the body count as an answer.


- Before pushing anything that touches a cross-language contract (`fixtures/`,
  `docs/contracts.md`), or really before pushing anything at all, run `scripts/test-all.sh`
  from the repo root. It runs `pnpm typecheck`, `pnpm test`, and the Swift suite in one
  command (#595). This matters even more since #1347: CI no longer runs the Swift tests at
  all (only `typecheck-and-test`, on GitHub-hosted ubuntu-latest), so a local run is the ONLY
  thing that verifies the Mac app before it reaches main. The mandatory local pre-push gate
  judges that each change carries a test (and enforces the style rules); it does NOT itself run
  the suites, so `test-all.sh` is what actually runs the full Mac suite plus the TypeScript side
  that CI would otherwise only surface minutes later. Run it before every push.
- One-time per CLONE: run `scripts/install-git-hooks.sh` once (#1251 Phase 3). Once per clone is the
  whole of it: `core.hooksPath` lives in the shared git config (this repo sets no
  `extensions.worktreeConfig`), so every worktree, including ones made later, inherits it without
  running anything. Measured on 2026-08-09 across 11 worktrees, all of which had it.
  It points git at `scripts/hooks`, which holds two hooks. `post-merge` regenerates a stale
  `mac/Overture.xcodeproj/project.pbxproj` after a merge that combined Mac source changes and
  stages it for you to commit. It is only a convenience (it cannot fire after a conflicted merge
  finished by a manual commit); `scripts/check-pbxproj-fresh.sh` remains the real gate.
  `pre-push` (#2291) refuses a push whose destination is `main`, including a deletion of it. Work
  reaches main by pull request, and the checks that make a merge safe run on that path only, so a
  direct push skips every one of them at once: one did on 2026-08-07, and the only sign was
  `HEAD -> main` in the push output. A deliberate direct push is still possible with
  `ALLOW_PUSH_TO_MAIN=1 git push ...`, which announces itself rather than passing silently.
  #2291 also proposed GitHub branch protection as the stronger half, since a server side rule cannot be
  absent the way a local hook can. **Dan's call, 2026-08-09: declined, and not an open to-do.** It needs
  GitHub Pro on a private repo (both the branch protection and rulesets APIs answer 403 Upgrade to
  GitHub Pro, measured 2026-08-08), and what it would buy was measured rather than assumed: the direct
  push that caused the issue came from an ordinary working clone, which has the hook, and all 11 agent
  worktrees on this Mac have it too, because `core.hooksPath` lives in the shared config (there is no
  `extensions.worktreeConfig` here), so every future worktree inherits it without running the installer.
  What remains uncovered is only a FRESH CLONE elsewhere whose owner skips `scripts/install-git-hooks.sh`
  and then pushes straight to main. Revisit if this ever becomes a repo more than one machine clones.
  Since #2557 that same installer also registers a MERGE DRIVER, for the same per-clone reason
  (`merge.<name>.driver` lives in the git config, which is not tracked, and which every worktree shares).
  `.gitattributes` sends this repo's two GENERATED files, `docs/copy-inventory.md` and
  `mac/Overture.xcodeproj/project.pbxproj`, to `scripts/lib/merge-generated.sh`. Any two branches that
  touch the app's wording or its file list conflict on those by construction, and the conflict carries no
  decision: neither side's text is anybody's to write. Measured 2026-08-11, two branches in a row cost a
  manual resolve plus two full suite runs each, roughly twelve minutes apiece, for nothing.
  The driver keeps one side and DOES NOT regenerate, which is the part to understand before changing it.
  Git runs a merge driver per file while the merge is still in progress, so the worktree it would read is
  not the merged tree, and a generator run at that moment produces output derived from a state that never
  existed while looking exactly as authoritative as a correct one. The freshness gates settle the content
  afterwards, on the complete tree, and they are unchanged: `scripts/check-pbxproj-fresh.sh` blocks on a
  stale project file (measured: it blocks on the auto-resolved commit, naming the file), and
  `CopyInventoryTests` fails the Swift suite on a stale inventory. Both ride along in
  `scripts/test-all.sh`. The driver REFUSES any path outside those two rather than resolving what it is
  handed, so a mistyped `.gitattributes` line leaves a conflict to read instead of silently dropping
  somebody's work. A clone that never runs the installer just gets git's ordinary text merge, which is
  what this repo had before, so skipping it is no worse than the old behaviour.
- Keeping the checkout tidy: `scripts/tidy-checkout.sh` (#2234) removes local branches and agent
  worktrees whose work has provably shipped. It is a DRY RUN by default and needs `--apply` to
  delete anything. Note WHY it exists rather than the one-line idiom: this repo squash-merges, so a
  shipped branch is never an ancestor of main and `git branch --merged main -d` recognises almost
  none of them (39 of 496, measured 2026-08-06). It proves containment by a merged PR or by
  `git cherry`, keeps anything with an open PR, anything a worktree has checked out, and any
  worktree holding uncommitted work, and answers every unanswerable question in the keep direction.
  From #2234 both merge scripts also delete the local branch they just merged, since
  `gh pr merge --delete-branch` only removes it on GitHub, which is where the backlog came from.
- Reclaiming Xcode's build output: `scripts/reclaim-orphan-derived-data.sh` (#2585) deletes the
  DerivedData folders belonging to worktrees that no longer exist. It runs by itself inside every
  `scripts/test-all.sh`, so there is nothing to remember; run it by hand only to act immediately.
  Worth knowing WHY it is separate from the tidy script above. Every other toolchain here caches
  INSIDE the project directory (`node_modules`, `.next`, `venv`, `__pycache__`), so deleting a
  worktree reclaims all of it for free. Xcode is the exception: its cache lives outside the checkout
  and is keyed by the checkout's PATH, so every worktree that is ever built mints a fresh folder of
  roughly 1.6 GB that nothing reclaimed. This repo used to mint those paths constantly (one throwaway
  worktree per pre-merge verification, one per parallel agent; since #2601 verification reuses one
  fixed slot, so agents are the remaining minters), so the growth is proportional to how
  much the workflow is used and its ceiling is the disk. It reached that ceiling on 2026-08-12: 148 GB
  across 105 folders, 101 of them pointing at directories already deleted, and 132 MiB free on a
  926 GiB volume, at which point no command could run at all, including `df`, because the harness
  could not write the command's own output file. The rule it reclaims by is narrow on purpose: a
  folder whose `WorkspacePath` no longer EXISTS can never be reused, so deleting it costs nobody a
  rebuild, and that is a far safer question than how old is too old. Anything it cannot settle is
  kept, including a workspace on a volume that is merely unmounted. The three SHARED caches
  (`ModuleCache.noindex`, `CompilationCache.noindex`, `SDKStatCaches.noindex`, another 44 GB when
  measured) are only counted, never swept, because clearing them costs every project on the Mac one
  slow build; `--clear-shared-caches` does it when that is what you want. `verify-and-merge-branch.sh`
  stopped minting folders altogether (#2601): it verifies in one persistent worktree at
  `~/.overture-verify-worktree`, scrubbed to a fresh checkout per run, whose single build folder is
  kept warm on purpose (a cold path cost 75s more than a warm one, measured 2026-08-12) and survives
  the sweep because its workspace exists. Agent worktrees under `.claude/worktrees/` are torn down by
  the Claude Code harness, which this repo cannot hook, so those are what the sweep is for.
  `tidy-checkout.sh` reports the same thing in its dry run and reclaims it under `--apply`, following
  its own mode rather than carrying a second one. It DELEGATES to the script above rather than
  reimplementing the rule, so there is one definition of what can never be used again instead of two
  that can drift apart.
- Importer: `pnpm test`, `pnpm typecheck`, `pnpm import-history <csv-path>` (one-shot booking
  history import, see `docs/import-history.md`). The scout itself is entirely native; see
  `docs/scout-runbook.md`.
- Mac app: `cd mac && xcodegen generate`, then `./scripts/run-tests-locked.sh` (wraps
  `xcodebuild -scheme Overture -destination 'platform=macOS' test` in a lock so it can't
  collide with another test run on this Mac; use it instead of raw `xcodebuild test`). A
  scoped `-only-testing:OvertureTests/<Suite>/<test>` run prints `** TEST SUCCEEDED **` with 0
  tests executed if the path doesn't match anything (for example a `@Suite("...")` display name
  that differs from its Swift type name), and raw `xcodebuild` exits 0 on it, indistinguishable
  at a glance from a real pass.
  Since #2317 that is caught rather than watched for: pass the scope to the WRAPPER
  (`mac/scripts/run-tests-locked.sh -only-testing:OvertureTests/<Suite>`) and a run that reported
  success while executing no tests at all fails with `NOTHING RAN`, naming the scope as the likely
  cause. That is the reason to scope through the wrapper rather than around it; a raw `xcodebuild`
  still has no gate on it. A scoped run is also exempt from the short-run baseline, and cannot move
  it: the baseline is a full-suite number, so a handful of tests would otherwise read as a 99%
  truncation and then quietly become the bar every later run is measured against.
  Since #2577 the wrapper also says whether the run is still MOVING, which `NOTHING RAN` cannot,
  because that gate can only speak once a run has ended and the run it exists for never ends. On
  2026-08-12 a hang inside a test's untimed wait loop (#2576) went unnoticed for over an hour while a
  second run sat blocked behind the shared lock, and three consecutive status reports said "waiting on
  the suite" when the work had been dead throughout. So the wrapper watches its own log for lines
  REPORTING a test or suite starting or finishing, and prints a loud `NO TEST HAS FINISHED FOR ...`
  once nothing has reported for the stall limit, repeating on that cadence and withdrawing itself if
  progress resumes. It never judges by the log GROWING: that hang wrote 21MB of repeated CoreData
  errors while standing still, so every byte-based or mtime-based signal called it healthy the whole
  time. It WARNS rather than kills, because a wrong kill throws a whole suite's work away and reports
  as a failure nobody caused; the cost of warning is that somebody still has to act on it, and the
  lock stays held until they do.
  Waiting for the shared lock is deliberately NOT a stall and can never trip it. That distinction is
  the whole guard: with several worktrees on this Mac contending for one lock, a run that has not
  started yet is the ordinary case, and a guard that called it a stall would be switched off within a
  day. It is told apart by evidence rather than by a threshold, since flock prints nothing until it
  hands the lock over, so a queued run's log is EMPTY and that is proof rather than inference. That
  state gets its own `STILL WAITING for the shared xcodebuild lock` notice, and a `Got the shared
  xcodebuild lock after ...` line when the wait ends, so a queued run is no longer silently
  indistinguishable from a hung one. The build phase is exempt for the same evidential reason: no run
  has been observed to hang there, so there is no measured number to set a limit from. Retune with
  `OVERTURE_TEST_STALL_LIMIT_SECONDS`, `OVERTURE_TEST_STALL_CHECK_SECONDS` and
  `OVERTURE_TEST_LOCK_NOTICE_SECONDS`.
  How long a full run takes is deliberately NOT written down here. It moved as the suite grew and
  the stated figure was wrong by minutes, which matters because the paragraph above tells you to
  check a suspiciously fast run against what a full one costs: an understated number weakens the
  very warning it was there to support (#2532, L32). Every run ends with its own `Suite shape:`
  line giving the wall clock it actually took, so read that.
- **Judging whether a script succeeded: capture its status directly, never through a pipe.**
  `some-script.sh | tail -5` reports `tail`'s exit status, not the script's, so a script that died
  instantly on an unbound variable and printed nothing at all reads as a clean pass. That happened
  on 2026-08-11 to a merge-script fixture and sent the next twenty minutes in the wrong direction
  (#2502). It is the same shape as the `NOTHING RAN` trap above, and the habit that hides it (piping
  through `tail` or `rg` to keep the output short) is exactly the habit anyone working at speed
  reaches for. Two tells worth knowing: NO OUTPUT AT ALL from something that normally prints a line
  per check means it died rather than passed, and `set -o pipefail` or `${PIPESTATUS[0]}` is what
  makes the reading honest when a pipe is genuinely wanted.
- **Writing a shell fixture: the assertions come from `scripts/lib/shell-assertions.sh`, which every
  `*.test.sh` sources.** It gives one vocabulary (`pass`, `fail`, `assert_contains`,
  `assert_not_contains`, `assert_equals`, `assert_eq`, `assert_empty`), all reporting through
  `FAILURES` and none exiting early, so a fixture runs every check it has and reports the total.
  Before #2501 each of the 48 fixtures defined its own, and which names existed varied file to file
  (22 had `assert_contains`, 13 `assert_equals`, 10 `assert_eq`), so reaching for the wrong one printed
  `command not found` to stderr, checked nothing, and the fixture still reported every assertion
  passing. `scripts/run-shell-fixtures.sh` now fails any fixture whose output shows bash could not
  resolve a command, which is the half that holds even if a fixture forgets to source the library. A
  fixture that drives a missing dependency ON PURPOSE (`models.test.sh` runs `record_model` with `PATH`
  pointing at nothing) prints `shell-fixture-expects-missing-command: <name>` to declare it; that
  exempts the one command named and nothing else. A fixture keeping its own definition of a helper is
  fine and deliberately still supported: two fixtures read `assert_contains` as
  (desc, needle, haystack), and a definition after the source line wins.
- **Quoting a character the style gate forbids: write it as an escape, never override the gate.**
  The pre-push style gate blocks any new line holding an em dash, en dash or emoji, and it cannot
  tell a line that USES one from a line that must QUOTE one, which is the gate working correctly.
  The answer is to build the character rather than type it, so the file holds no literal one:
  `mac/scripts/lib/suite-stats.test.sh` is the worked example (#2193), where a fixture legitimately
  needed the marks Swift Testing prints and builds them from their UTF-8 bytes with `printf`. In
  Swift the same trick is a unicode escape (`\u{2014}`). `SKIP_STYLE_CHECK=1` is visible and
  tempting and skips past a clean solution, so it is the wrong tool here (#2312).
- **This repo turns four Claude Code plugins off, in a TRACKED settings file.** `.claude/settings.json`
  gives `vercel-plugin@vercel-vercel-plugin`, `cloudflare@cloudflare`, `figma@claude-plugins-official`
  and `stripe@claude-plugins-official` a `false` under `enabledPlugins`, and
  `scripts/check-project-plugin-scope.sh` (#2605) fails if any of that stops being true. Plugins are
  enabled at user scope in `~/.claude/settings.json`, so they fire in every project on this Mac whatever
  the project is: measured 2026-08-13, one session opened here with a single one-line prompt carried
  53.2KB of injected Vercel documentation, a CLI upgrade nag, and `You must run the Skill(...)` lines
  under a heading reading `MANDATORY: Your training data for these libraries is OUTDATED and
  UNRELIABLE`. None of it is true of a SwiftUI app plus a `tsx` importer. #1682 had already measured the
  same plugin doing the same thing to the DETACHED runs and fixed it there
  (`claude_run_plugin_lockout`), deliberately covering only the runs this repo launches, so the
  interactive session kept paying for it. Three details worth keeping. TRACKED rather than
  `.claude/settings.local.json`, because local settings are excluded by Dan's global gitignore and live
  per checkout, so every agent worktree would keep getting the text (his call, 2026-08-13). The test for
  it names the four ids independently rather than reading them back from the script's own list, so
  dropping one from both places still goes red (L70). And `swift-lsp`, `superpowers` and `plannotator`
  stay ON deliberately, since all three are in use here, which the same test asserts so a later sweep
  cannot quietly take them out. Hooks only load at session start, so a change here cannot be verified in
  the session that makes it.
- Since #1967 the Swift tests live in TWO targets, and which one a new test belongs in is decided
  by one question: does it need the app RUNNING?
  - `OvertureTests` (`mac/OvertureTests/`) holds almost everything and is where a new test goes
    unless it renders a view. It is UNHOSTED: it reaches the app's code by compiling it in, not by
    linking a host, so it has no `TEST_HOST` and no dependency on the app target at all.
  - `OvertureHostedTests` (`mac/OvertureHostedTests/`) is only the ViewInspector ones, which render
    a real SwiftUI view and so genuinely need the host process. It is a small fraction of the total.
  - `mac/TestSupport/` holds the helpers both compile (`SourceGuardHelper`, `SwiftSource`,
    `CopyInventory`), in one place so a guard helper cannot drift between the two targets.
  This exists because every test used to run inside the launched app, so one launch fault took all
  of them: on 2026-08-01 a crowded menu bar removed the status item, which terminates a
  `MenuBarExtra` app, and nothing in the Mac app could be verified at all. Measured ON 2026-08-02
  with a deliberate `fatalError()` in `OvertureApp.init`: the pure suite reported
  `Test run with 4802 tests in 690 suites passed`, `** TEST SUCCEEDED **`, exit 0, while the app
  could not start. That figure is what the suite was THAT DAY and is deliberately not updated: it
  is the record of an experiment, not a claim about the suite's current size. For the current size,
  see the readout below.
- **The suite states its own size, every run.** `run-tests-locked.sh` ends with a
  `Suite shape:` line giving the tests and suites actually executed, the wall clock, the ratio of
  test Swift to app Swift, and how many test declarations are source-text guards (#2193, #2232).
  Use that line, never a number written in this file, as the reference for "did this run execute
  the whole suite?". The counts here used to be hand-written and both had drifted badly, which
  quietly weakened the warning two paragraphs up: a stated total is exactly what someone checks a
  suspicious scoped run against, so a wrong one is worse than none (L32). `AgentsDocSuiteCountsTests`
  fails if a hand-written count is ever put back.
- The pure suite has its own scheme, `OvertureCore`, which does NOT build the app. Use it
  (`xcodebuild -scheme OvertureCore -destination 'platform=macOS' test`) to verify domain logic while
  the app is broken or mid-refactor; it does not even need the app to compile. This matters because
  `-only-testing:OvertureTests` on the combined `Overture` scheme does NOT avoid the app: xcodebuild
  still prepares and launches the host, and a crash there decided the exit code even though every one
  of the pure tests passed. `run-tests-locked.sh` falls back to this scheme automatically on a CRASH, so
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
  a trust-settings password dialog); after that every build signs automatically. Since #2537 that setup
  proves its own work the same way `build-install.sh` does, by trial signing a throwaway bundle, rather
  than asking the cheaper question of whether an identity is LISTED. It was the script that answered that
  question wrongly first: on 2026-07-26 it printed `Done. Created and trusted ...` for a certificate
  codesign refused outright, and only `build-install.sh` found out, after a full Release build and after
  `/Applications/Overture.app` had already been replaced. Its early exit asks the same question, so an
  identity that is present and refused is recreated rather than reported as already set up. Every call in
  it that touches the real keychain or trust store sits behind a named function, which is what lets
  `mac/scripts/setup-signing-identity.test.sh` drive the whole decision path without the password dialog
  that made it untestable before. `build-install.sh` fails loud if that identity is missing rather than
  falling back to ad-hoc. The one-time switch to this identity re-prompts for permissions on the first
  install after it, then they persist.
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
  (#915), generated from the source and checked in. The test suite fails when it is stale, so a PR
  that changes the app's wording shows that change in the diff, in the words Dan will read rather
  than as a line of Swift. Since #1994 a failing run **writes nothing**: it names the sentences that
  moved and stops, because a run that was not asked to change the repo must not change it. (It used
  to rewrite the file in place, and on 2026-08-02 that put a `fatalError` string, added only to break
  the app on purpose, into the checked-in list of what Overture says to Dan, where a `git add -A`
  would have shipped it.) When the difference IS your copy change, regenerate and commit it:

  ```
  TEST_RUNNER_REGENERATE_COPY_INVENTORY=1 mac/scripts/run-tests-locked.sh
  ```

  The `TEST_RUNNER_` prefix is load-bearing, not decoration: xcodebuild does not pass its own
  environment to the test process, it forwards only variables with that prefix and strips it. The
  bare name is silently ignored. Copy that is NOT the app's own voice (an outbound email body, an RFC822 header,
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
  Read a section in EVERY BRANCH it can render, not just the populated one (#1547). The coverage box's
  explaining sentence was correct, tested and inside the has-gaps branch, so the state Dan was actually
  in (no gaps, some clients set aside) rendered the heading over a bare count and nothing else, reading
  as the exact opposite of what it meant. He asked what the section was for. A cold read of the diff
  cannot catch that, because the sentence it would have him read is the one that never appeared: the
  question to ask of each conditional is what this surface says when the list is EMPTY, when it holds
  one, and when the branch that carries the explanation is the one not taken.
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
  Remembering to run it was the whole mechanism, and it did not hold: the harness could not start at all
  from 2026-07-28 to 2026-07-31 (#1862) with nobody noticing, and two runbook edits (#1856, #1817) shipped
  before it had scored either. So `scripts/check-prep-eval-freshness.sh` (#1867) rides along in
  `scripts/test-all.sh` and WARNS when `docs/prep-runbook.md` has changed since the eval last completed.
  It never blocks (the eval spends tokens, so a gate would either be overridden every time or spend money
  by itself), it keeps "never run here" and "stale since a date" as separate messages, and it skips
  cleanly where the eval could not run anyway (no `claude` CLI, so CI and a fresh clone). What it reads is
  `.overture-eval-last-run`, written by the eval only AFTER its last fixture is scored and naming the
  runbook's content hash rather than any mtime: the dated `.overture-eval-runs/` directory is created
  before the first AI call, so a run that died there would leave one indistinguishable from a finished
  run's, and a clone rewrites every mtime.
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
  That re-run is against CURRENT main, not against the base the branch was cut from (#2353):
  `verify-and-merge-branch.sh` merges `origin/main` into its verify worktree before the suite
  is allowed to judge anything, and refuses (verifying nothing, merging nothing) when that combine
  conflicts. An agent's own green run only ever proves the branch works beside the code it was cut
  from, and when several branches land at once that is the one thing it needs to prove and cannot:
  PR #2345 was green on its own branch and red on the main that already carried #1575 and #1940
  (measured 2026-08-09). If you merge some other way, combine current main into the branch and
  re-run `scripts/test-all.sh` on the combined tree yourself before merging.

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
