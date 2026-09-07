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

**Where the detail is, and when to go and read it.** Every rule below states what it demands in a
line or two and names the file holding its evidence. Read the whole entry there whenever one of
these is about to decide something: the body is where the failure behind the rule is described, and
the rule on its own is routinely too short to apply correctly. Same arrangement, and the same
reason, as `~/.claude/LESSONS-INDEX.md` beside `LESSONS.md`.

Split out in #3640, when this file passed the character limit for a file loaded into every session
(150,888 against 150,000 on 2026-09-06, growing about 4,500 a day). Nothing was reworded on the way
out: those entries are dated measurements, and rewriting one destroys the record.

- **Before opening any PR, enumerate these five in the PR body. Not "checked": the actual list.**
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
  5. **PREMISE RE-CHECKED.** State what the issue's write-up claimed about the code, and what that code
     says TODAY. "The premise held" is a fine answer; naming what had changed is a better one. An
     absent answer is the defect, exactly as it is for the four above.
     An issue's premise is true as of the day it was filed, and nothing else asked anybody to check
     (L61). Overnight into 2026-08-14, three issues in a row had a stale one: #2657 said a ranking left
     the contact tier out when it already weighted it, so building to the write-up would have weighted
     it twice; #2675 named a field that does not exist, and the real gap was larger than the one
     described; #2656's calibration said a page had "room to spare" at 1,994 characters, and that venue
     now runs to 3,836, which is 96% of the budget. All three were caught by somebody happening to look.
     The matched phrase is `premise re-checked`, and it is a PHRASE because the bare word was measured
     and rejected: "premise" appears in 11 of the last 40 merged PR bodies (2026-09-04), none of them
     answering this question, so a guard on it would pass a body that re-checked nothing. That is the
     same trap the paragraph below describes for the other four.
     What this cannot do, stated so nobody expects it to: it checks the question was ANSWERED, never
     that the answer is any good, and somebody can type "premise: held" without looking. So can they
     for the other four, and those still surface real gaps, because the realistic failure is omission
     rather than fabrication. Its value is narrower: it puts the question in front of whoever is about
     to build, while checking is still cheap.

  A gap named in the PR body is fine. An unnamed one is the defect.

  **One exemption, and it is narrow (#2822).** A bot-authored PR can never answer this, so dependabot's
  bumps piled up unmerged and the dependencies went stale (measured 2026-08-16: #2752 and #2753 were both
  refused with all four items named). `scripts/lib/pr-completeness-guard.sh` exempts a PR when BOTH halves
  hold: the author is one of the named bots AND the diff touches nothing but dependency manifests and
  lockfiles. A bot PR that touches source still has new values in it and still needs the enumeration. The
  exemption ANNOUNCES itself in the output naming why, rather than passing silently, so a mis-scoped rule
  is visible. An empty file list is never exempt: empty is what a failed `gh` call returns.

  The check that enforces this matches five short phrases literally, `writer`, `reader`, `sibling`,
  `seen` and `premise re-checked`, so write the enumeration using them. It cannot read an answer, only find a word: PR #2526 answered
  the first question in full under the heading "the code path that WRITES it" and was refused for
  never saying "writer". Kept strict on purpose rather than accepting stems, because a looser match
  would let an incidental mention anywhere in the body count as an answer.

  **Two claims in a PR body are checked against the world rather than for presence (#3159), and they have
  DIFFERENT verdicts.** `scripts/lib/pr-body-claims.sh` runs in all three merge paths, and which half
  refuses was measured over the last 200 merged PRs before either was written.
  A `Closes` keyword fronting a comma separated LIST **refuses**. GitHub links an issue only where the
  keyword immediately precedes its number, so `Closes #a, #b, #c` closes exactly one and silently
  references the rest. The shape appears 4 times in 200 (#3146, #3142, #2851, #2848) and every one is the
  defect: two left an issue open that is still open (#2925, #3076), the other six were closed by hand days
  later. Write the keyword before each number. `ALLOW_UNLINKED_CLOSES=1` overrides one command and
  announces itself.
  A quoted decision date matching no comment on any issue the body names only **reports**, and the reason
  is worth knowing before anyone tries to make it a gate. 39 of those 200 bodies quote a decision with a
  date and 12 quote one no comment day carries, but nearly all of those are correct, because most of Dan's
  calls are made in the working session rather than in a comment: PR #3160 says so in its own body, #3114's
  decision lives on an issue it does not close, and #3164 quotes a session call that confirms an earlier
  comment. A gate there would refuse about one PR in five and be right about one of them (L93). What it
  prints instead is the quoted date beside the days the evidence really carries, which for PR #3142, the
  incident, is `quoted 2026-08-22` against `2026-08-18 2026-08-21`. It says nothing at all when there is no
  evidence, because a failed fetch and an issue with no comments must not read as a mismatch (L98).

  **Since #3187 that report also WRITES, once the merge is confirmed.** The reason the quoted date so
  often matches nothing is not that the quote is wrong: it is that most of Dan's calls are made in the
  working session, so the sentence lives only in a merged PR body, which is not somewhere anybody looks.
  `merge_pr` therefore posts the quoted SENTENCE, quoted as a blockquote and naming the PR it came from,
  to every issue the body closes, whenever no comment there carries that day. Dan's call, 2026-08-29
  (this session, in chat): automatic rather than a command printed for somebody to run, because a step
  that needs remembering is a rule living only in prose (L27). At the measured rate (8 PRs in 200) that
  is roughly one comment a fortnight.
  Four things about it are load bearing. It sits in `merge_pr` rather than in either caller, so all three
  merge paths get it from one place. It runs AFTER GitHub confirms MERGED and never before, because a
  call recorded for a PR that did not land is a decision nobody made sitting exactly where one somebody
  made would sit. It asks what is already on the issue first, so a rerun after a partial failure does not
  record the same call twice. And it writes NOTHING from an empty evidence pool, by the same rule the
  advisory already speaks by: a failed fetch must never become a durable comment asserting a mismatch
  nobody measured (L98, L119). The comment says in its own words that it is a record of what the PR
  claimed rather than a ruling, since the report it rides on is right about the date roughly seven times
  in eight and cannot tell which. `OVERTURE_NO_DECISION_COMMENT=1` turns it off for one command and
  announces itself, and says nothing at all when there was nothing to record.

- Before pushing anything that touches a cross-language contract (`fixtures/`,
  `docs/contracts.md`), or really before pushing anything at all, run `scripts/test-all.sh`
  from the repo root. It runs `pnpm typecheck`, `pnpm test`, and the Swift suite in one
  command (#595). This matters even more since #1347: CI no longer runs the Swift tests at
  all (only `typecheck-and-test`, on GitHub-hosted ubuntu-latest), so a local run is the ONLY
  thing that verifies the Mac app before it reaches main. The mandatory local pre-push gate
  judges that each change carries a test (and enforces the style rules); it does NOT itself run
  the suites, so `test-all.sh` is what actually runs the full Mac suite plus the TypeScript side
  that CI would otherwise only surface minutes later. Run it before every push.
  Since #2603 it runs in TWO LANES, which changes how to read its output. The Swift suite starts FIRST,
  in the background, and the cheap checks (typecheck, vitest, the shell fixtures, the drift checks) run
  beside it, so the whole command now costs about what the Swift suite costs alone: measured 2026-08-13,
  the cheap lane took 54s on its own and a full two-lane run took 200s against a Swift suite of 177s.
  Three consequences. The Swift output does not appear until the cheap lane finishes, then replays from
  its first line, so a quiet minute at the start is the cheap lane working rather than a hang (its own
  stall guard cannot be starved by this: the limits are 600s and 300s, an order of magnitude past the
  cheap lane). A failing cheap check no longer ends the run, because the expensive lane is already going
  and its verdict is worth having, so the run says `FAILED - <check>` as it happens and both lanes are
  reported separately at the end; the exit code is red if either lane is red (L53). And two checks
  deliberately stay ahead of the build, `check-pure-suite-imports.sh` (its whole value is saving a doomed
  build, which only works before one starts) and `check-pbxproj-fresh.sh` (it regenerates and restores
  the project file, which must not happen while xcodebuild is reading it).

- Importer: `pnpm test`, `pnpm typecheck`, `pnpm import-history <csv-path>` (one-shot booking
  history import, see `docs/import-history.md`). The scout itself is entirely native; see
  `docs/scout-runbook.md`.

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

### Running and reading the suites: `docs/agents/testing.md`

- Run the Swift suite through `mac/scripts/run-tests-locked.sh`, never a raw `xcodebuild`. The
  wrapper holds the machine-wide lock, and it is the only thing that refuses a run which reported
  success while executing nothing. Pass any `-only-testing:` scope TO the wrapper, not around it.
- Every run ends with a `Suite shape:` line saying what actually executed and what it cost. That
  line is the reference for whether a run was short, never a figure written down anywhere. It says
  NOT REPORTED rather than summing across a run whose test process restarted.
- Two lines beside it say whether this run verified the SCREENS, and whether the live store
  invariants measured anything at all. Both keep "did not measure" apart from "measured and passed".
- Which test entry points refuse to call an empty run a pass, and which structurally cannot. A raw
  `xcodebuild` cannot. A `cmd | grep -q` under `pipefail` answers FALSE on an early match.
- The tests live in two targets. A new one goes in `OvertureTests` unless it renders a SwiftUI view.
  `OvertureCore` is the scheme that does not build the app.
- Proving a guard works: `scripts/mutate.sh`, never a hand-rolled one-liner. Put `--at` FIRST,
  escape `\$` and `\@`, and read which of its eleven outcomes it actually gave you.
- Waiting inside a Swift test: `waitUntil`, which suspends and carries a deadline. Never a bare
  `while !condition { await Task.yield() }`, which cannot fail and can only hang.
- Writing a shell fixture: source `scripts/lib/shell-assertions.sh`, and run it through
  `scripts/run-shell-fixtures.sh`, which is where the rules that judge a fixture live.

### Diagnostic and check scripts: `docs/agents/diagnostics.md`

Each entry says what the script asks and how to read an answer that is usually three outcomes rather
than two, the third being UNMEASURED. Opt in unless the entry says it rides along.

- `scripts/check-fixtures-do-not-age.sh`: does the suite care what year it is. Run it after adding a
  dated fixture. A new entrant is a test to look at, not a defect.
- `scripts/check-far-future-fixtures.sh`: does a far-future fixture still assert anything, or has it
  become permanently outside every window.
- `scripts/check-temp-dir-leaks.sh`: does the suite clean up the scratch directories it makes.
- `scripts/check-test-identity-provenance.sh`: does test data name a real person. Reports rather than
  refuses, and its baseline grows.
- `scripts/check-main-actor-share.sh`: how much of the suite is pinned to the main actor. Advisory,
  rides along in `scripts/test-all.sh`.
- `scripts/check-test-shared-state.sh`: which test harnesses hold state for the whole process.
  Advisory, rides along.
- `scripts/check-producer-corpus-drift.sh`: has the producer rule's calibration fallen behind the
  live feed. Reaches the network.
- `scripts/check-fixture-corpus-drift.sh`: has a fixture sized against the live store fallen behind
  it. Rides along; a declaration joins it by carrying the live shape tag the script defines.
- `scripts/find-tests-naming.sh`: before implementing a decision Dan has REVERSED, list the tests
  that assert the old one, so they are deleted rather than left defending it.
- `scripts/what-the-check-searched.sh`: what a contact check actually searched for, per archived run.
- `scripts/analyse-freeze-load.sh`: where the freeze tool's busy threshold lands in this Mac's real
  distribution of load.
- `scripts/scroll-wheel.sh`: scroll the running app from a script. It drives Dan's machine, so it
  refuses without `--yes`.
- `scripts/measure-concurrent-runs.sh`: two runs going at once. Spends real usage, refuses without
  `--yes`, and is a Dan-at-the-machine job rather than an agent one.
- The app records its own freezes: `MainThreadWatchdog` writes `freeze-log.ndjson` beside the store,
  and the app says at launch what the last session's worst stall was.

### Shell conventions: `docs/agents/shell.md`

- Judge a script by its EXIT STATUS, never through a pipe. No output at all from something that
  normally prints a line per check means it died, not that it passed.
- A script that changes its own working directory captures its location BEFORE the `cd`.
- `find` inside a script is the real `find`. Only a command typed into a session is shimmed.
- Scratch goes through `overture_scratch_dir` and `overture_scratch_file`, never a bare `mktemp`,
  which on macOS ignores `TMPDIR` and writes where no check here can see.

### Builds, and per clone setup: `docs/agents/builds.md`

- Once per clone: `scripts/install-git-hooks.sh`. It installs the post-merge regeneration of the
  project file, the pre-push refusal of a direct push to `main`, and the merge driver that resolves
  this repo's generated files.
- To LOOK at the app: `mac/scripts/run-debug.sh`, which refuses to launch a bundle claiming the
  Release identity. Release installs with `mac/build-install.sh`, after
  `mac/scripts/setup-signing-identity.sh` once per Mac.
- `mac/build-install.sh` builds whatever is checked out. The freshness panel's Update button runs
  `mac/scripts/update-overture.sh` instead, which only ever fast-forwards `main` and refuses
  anything else.
- `scripts/reclaim-orphan-derived-data.sh` reclaims Xcode's build output for worktrees that no
  longer exist. It runs by itself inside `scripts/test-all.sh`.
- The committed `mac/Overture.xcodeproj/project.pbxproj` is generated, and nothing in CI checks it.
  `scripts/check-pbxproj-fresh.sh` is that gate, and it judges against HEAD rather than the index.

### Worktrees, parallel agents, and merging: `docs/agents/merging.md`

- Several sessions share this repo. Give each agent its own worktree, keep `xcodebuild` serialized
  under the shared lock, and never switch or delete a branch this session did not create.
- A branch is verified against CURRENT main before it merges, never against the base it was cut
  from: `scripts/verify-and-merge-branch.sh`, or `scripts/verify-and-merge-batch.sh` for several at
  once, which pays for one combined suite run instead of one per PR.
- `scripts/tidy-checkout.sh` removes local branches and worktrees whose work has provably shipped.
  Dry run by default, `--apply` to delete anything.
- When a decision is recorded on an issue, edit the issue BODY in the same action. The thread is the
  record of how it was reached and is not rewritten; the body is what anybody triaging reads.
- CI is one check, `typecheck-and-test`, on pull requests only. The Swift suite runs nowhere but
  locally, so a merge's Swift verification is a local `scripts/test-all.sh` you have seen pass, and
  a Mac change never goes in through a bare `gh pr merge`.

### The app's words, and the drafting rules: `docs/agents/copy.md`

- `docs/copy-inventory.md` is every sentence Overture can say to Dan, generated from the source and
  checked in, so a wording change shows up in the diff as words rather than as Swift. Read the new
  and changed lines COLD before opening the PR, in every branch the surface can render, including
  the empty one. `docs/outbound-copy.md` is the same for email going to strangers and gets its own
  cold read, asking a different question: what state is this sentence only ever sent in, and is
  every clause true of that state? `docs/copy-surfaces.md` says where each sentence lands.
- Regenerate with `TEST_RUNNER_REGENERATE_COPY_INVENTORY=1 mac/scripts/run-tests-locked.sh`. The
  `TEST_RUNNER_` prefix is load bearing; the bare name is silently ignored.
- The AI drafting rules live in the `dan-wright-brand-voice` skill, which always wins, mirrored in
  `docs/prep-runbook.md`. `scripts/check-brand-voice-drift.sh` rides along and warns on drift.
- The runbook encodes judgment rather than code, so it has a regression harness.
  `scripts/eval-prep-runbook.sh --yes` spends tokens and is in no CI job: run it by hand before
  shipping a runbook edit.
- A store-wide count quoted in prose carries its date, or is not quoted at all.
- Quoting a character the style gate forbids: build it as an escape so the file holds no literal
  one. Never `SKIP_STYLE_CHECK`.

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
