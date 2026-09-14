# Branches, issues, merging and CI

How work reaches main: the git hooks, the verify and merge scripts, the project file freshness gate, what CI does and does not cover, and keeping the checkout tidy.

A body file for `AGENTS.md`, which carries the one line form of every rule below plus a pointer
here. The index line is enough to tell you a rule APPLIES; it is not enough to apply it, because
the measurement it came from lives here. Read the entry before the rule decides anything.

## Git hooks, one time per clone

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
  `.gitattributes` sends this repo's GENERATED files to `scripts/lib/merge-generated.sh`: all three
  generated copy documents (`docs/copy-inventory.md`, and since #3221 `docs/outbound-copy.md` and
  `docs/copy-surfaces.md`, which arrived with #2946 and had never been registered) plus
  `mac/Overture.xcodeproj/project.pbxproj`. Any two branches that
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

## Keeping the checkout tidy

- Keeping the checkout tidy: `scripts/tidy-checkout.sh` (#2234) removes local branches and agent
  worktrees whose work has provably shipped. It is a DRY RUN by default and needs `--apply` to
  delete anything. Note WHY it exists rather than the one-line idiom: this repo squash-merges, so a
  shipped branch is never an ancestor of main and `git branch --merged main -d` recognises almost
  none of them (39 of 496, measured 2026-08-06). It proves containment by a merged PR or by
  `git cherry`, keeps anything with an open PR, anything a worktree has checked out, and any
  worktree holding uncommitted work, and answers every unanswerable question in the keep direction.
  From #2234 both merge scripts also delete the local branch they just merged, since
  `gh pr merge --delete-branch` only removes it on GitHub, which is where the backlog came from.
  What that does NOT cover is every path that is not a merge script (a branch made by hand and
  abandoned, an agent worktree, the bare one-line merge the next-issue shortcut uses), so since #2302
  `scripts/check-branch-backlog.sh` rides along inside `scripts/test-all.sh` and prints one line when
  the count of local refs has climbed past its threshold. Advisory only, never blocking, and it
  counts REFS rather than dead ones: it says so, and hands the expensive question to the script
  above, because the tidy's own counting pass reads every merged PR head branch from GitHub and then
  computes a patch-id per commit, which is far too slow to sit inside every push. The reason it
  exists at all is that nothing counted: the 496 accumulated with the obvious command agreeing all
  was well the whole way up. The other repos named in #2302 (nursedex, playedit, PostRoll, Downbeat)
  were NOT measured or covered here; that half of the issue is still open.

## When a decision is recorded on an issue

- **When a decision is recorded on an issue, edit the BODY in the same action (#3077).** Say which of
  its open questions are now settled, what the answer was, and point at the comment. The thread stays
  untouched: it is the record of HOW a decision was reached and must not be rewritten. The body is what
  anybody triaging actually reads, and nothing carries the outcome back to it.
  Measured on #2915, 2026-08-21. Its body listed five things that had to be settled. Dan settled three
  of them in a comment on 2026-08-18. The overnight review of 2026-08-20 read the body, reported the
  issue as needing "five product decisions", and set it aside as blocked on him. It was one decision
  away from buildable, and a whole session's triage went at a stale sentence.
  `scripts/check-issue-open-questions.sh` is the advisory half, because a rule living only in prose is
  a hope (L27). It lists open issues whose body names open questions AND that carry a comment, for a
  person to reconcile. Deliberately NOT a gate and deliberately not clever: a comment on such an issue
  is usually not a decision, so anything that judged would be wrong in the direction that hides the
  real ones (L93). Measured before it was built: 16 open bodies name open questions under its
  phrasings and 4 of those carry a comment, which is a list somebody reads. It is OPT IN rather than in
  `scripts/test-all.sh`, since it needs the network and answers about the backlog rather than the code;
  its judging half rides along on every push through `scripts/check-issue-open-questions.test.sh`.


## Running several agents at once, and how a branch is verified and merged

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
  For SEVERAL PRs at once use `scripts/verify-and-merge-batch.sh <pr> <pr> ...` (#2602), which does that
  combination once instead of once per PR: it refuses every PR up front that cannot be in a batch (an
  unresolvable identifier, a GitHub-side conflict, a PR named twice, a body missing the completeness
  enumeration), sets the persistent verify worktree to current `origin/main`, merges each branch in,
  runs `scripts/test-all.sh` ONCE, and merges them all only on green. It reuses
  `verify-and-merge-branch.sh`'s own functions rather than copying them, so the two paths cannot
  disagree about what a mergeable PR looks like. Two things to know before reading its output. On red it
  says the failure belongs to the COMBINATION and names every branch in it, because a combined run
  genuinely cannot attribute a failure to one branch, so do not read it as the last branch named. And
  the merges themselves happen one at a time on GitHub, so one can be refused after the others land;
  it attempts all of them and its summary says which merged and which did not, rather than stopping at
  the first refusal and leaving the rest unreported.
  **A refusal on GitHub's CONFLICTING flag now says WHICH KIND of collision it is (#3210).** Both merge
  paths ask `check_mergeable_locally` (`scripts/lib/generated-conflict.sh`) rather than
  `check-pr-ci.sh`'s `check_mergeable`, and it still refuses every CONFLICTING PR. What it adds, in
  seconds, is the half nobody could see: GitHub computes that flag with a plain text merge and cannot
  see this repo's `.gitattributes` merge driver, so a PR whose only collisions are the generated files
  is flagged while a trial `git merge-tree` here resolves it and exits 0. Any two branches touching the
  app's wording or its file list collide that way by construction, which is the whole reason the driver
  exists, and telling that apart from a real conflict used to cost a full extra suite cycle (measured
  2026-08-28 on PR #3196). The cheap kind now names itself and hands over the three commands that bring
  the branch up to main; the real kind names the files that actually collide. Those commands include a
  `git commit` step and say why: bringing main in fires `scripts/hooks/post-merge`, which regenerates a
  stale project file and leaves it STAGED, so a push without that commit arrives carrying the staleness
  the merge gate then refuses. The same block says `scripts/test-all.sh` JUDGES the generated documents
  rather than regenerating them, and names `TEST_RUNNER_REGENERATE_COPY_INVENTORY=1` for the one that
  does. A remedy naming a step that does not change the state the reader is stuck in is worse than none
  (L111), and the first version of this message had both halves wrong.
  **It does not carry on, and that is deliberate.** GitHub will not merge a PR it reports as CONFLICTING
  whatever this Mac resolves, so carrying on would buy a full suite run and then fail at the merge. The
  evidence is PR #3196's own commits, which carry a pushed merge of main AND a pushed
  `Regenerate project.pbxproj` before it would go in. Automating that means pushing a regenerated file
  to somebody's branch, which is exactly the property #2812's safety argument leans on not being true,
  so it is #3216 rather than a detail of this.
  The three outcomes are kept apart on purpose: resolved, really conflicted, and NOT MEASURED (the fetch
  failed, or git refused the trial merge). A trial merge git declined to attempt exits 1 exactly as a
  conflicted one does, so what separates them is evidence rather than a status code, the tree OID a real
  merge writes (L98, L11).
  **Both merge paths now judge each side's project file BEFORE merging, and COMMIT the regeneration the
  post-merge hook makes afterwards (#2812).** Read the pair together, because either half alone is
  wrong. The hook regenerates a stale `mac/Overture.xcodeproj/project.pbxproj` after a merge and leaves
  it STAGED, so the batch's SECOND combine used to die on `Your local changes to the following files
  would be overwritten by merge` and the script refused, verifying nothing and merging nothing. Measured
  2026-08-16 combining #2809 and #2810. Two branches that each add a Swift file is the ordinary case, so
  the batch gave up exactly where one suite run instead of several is worth the most, and the
  `.gitattributes` merge driver never got a chance at it, because an uncommitted change blocking a merge
  is not a content conflict. What makes committing that regeneration DIFFERENT from the blind
  `xcodegen generate` of #1368, which is the whole distinction: #1368 regenerated the tree AS CHECKED
  OUT, before any merge and before the gate looked, so it corrected staleness the BRANCH carried and
  would land on main, and `check-pbxproj-fresh.sh` then compared the file to a version of itself that
  had already been fixed. This commit can only ever record a regeneration OF A MERGE RESULT, for a tree
  that exists nowhere but the verify worktree and is pushed nowhere, and every ref going into it
  (`main` and each branch) has already had its OWN committed file judged, unmodified, on its own tip.
  So the gate keeps its teeth: a branch carrying a stale project file is still refused, and it is
  refused before anything regenerates, naming the branch rather than letting the failure surface later
  as a stale file on main. A genuine content conflict still refuses exactly as before. The commit is
  also refused, rather than made, if anything OTHER than the file the hook owns is staged.
  **Since #2946 both merge paths also REBUILD the three generated copy documents on the combined tree**
  (`docs/copy-inventory.md`, `docs/outbound-copy.md`, `docs/copy-surfaces.md`), through
  `scripts/lib/copy-docs-rebuild.sh`, before the suite runs. Same shape and same reason as the project
  file above: the instant any change adding a Dan-facing sentence merges, every other open branch holding
  those files is stale, and the rebuild carries no decision because neither side's text is anybody's to
  write. Measured 2026-08-18 across ten issues: three extra full suite runs plus two hand rebuilds. The
  per-branch gate it leans on is NOT weakened and is not moved: a branch whose author changed the app's
  wording and did not regenerate could never have had a green local `scripts/test-all.sh`, which is
  mandatory before a push, so the only staleness that can survive to the combine is staleness another
  branch caused. It commits ONLY those three paths and refuses when the run left any other TRACKED file
  modified. An untracked stray is deliberately not a refusal, since only those three are ever staged and
  refusing would block a merge over a log file a run happened to drop. And the cold read is untouched:
  reading the new sentences is the author's step, on their own branch, where the change is theirs.

  **A merge is confirmed with GitHub, never assumed, and that is one shared implementation**
  (`scripts/lib/pr-merge.sh`, used by all three merge paths). Both halves of that come from the same
  incident, on the batch script's first real run, 2026-08-13: `gh pr merge 2609` exited 1 with
  `GraphQL: Something went wrong while executing your query`, a transient GitHub fault, and the run
  printed `merged   PR #2609`, deleted the local branch of a PR that was still open, and exited 0.
  Nothing had looked at the merge command's status (the steps after it ran unconditionally and the last
  two end in `|| true`, so the function returned 0; errexit cannot help, because every caller invokes it
  where errexit is suspended), and a zero status would only have been a claim about the command anyway,
  not about the PR. So `merge_pr` now fails loud on the command AND asks GitHub whether the PR reads as
  MERGED, and nothing destructive runs until it does. `pr-merge.test.sh` asserts no other script invokes
  `gh pr merge` itself, because the reason this needed fixing twice is that two scripts each had their
  own copy.


## Why there is no push trigger, and why there is no paths filter

That one check runs on PULL REQUESTS ONLY. There is no push trigger, and
`src/lib/ciWorkflow.test.ts` fails if one comes back. The reason is DUPLICATED WORK, measured
2026-08-16: 440 workflow runs over seven days, 209 of them push and 227 pull_request, so about half
of every run this repository made was a second look at code that had already passed.
This paragraph used to give the reason as MONEY, and that half was wrong (#3233, L32). It said
the 209 push runs were roughly 1,890 billed minutes a month against the 2,000 a PRIVATE repo gets
on a free personal plan, and that crossing it would stop CI rather than bill. This repository is
PUBLIC (`gh repo view --json visibility` answers PUBLIC, checked 2026-08-29) and GitHub does not
bill a public repository for standard hosted runners, so no run here has ever cost money. It does
NOT follow that a duplicate run is free, which is the same mistake pointing the other way (L307):
on a free public repository the budget is the RUNNER CONCURRENCY LIMIT, a job is priced in the
slots it holds times how long it holds them whoever is waiting, and every job over the limit
delays every other. Dropping half the runs is therefore worth more here than the old paragraph
claimed, in queue time rather than dollars. It is corrected rather than removed because it was
load bearing in the direction that matters: anybody weighing whether to add a job read it as a
measurement saying there was no room for one.
What the push run was FOR is the one thing a PR run cannot do, judge the MERGED result rather
than the branch beside the base it was cut from (L85). That is kept, and more strongly: both
merge scripts already combine current `origin/main` into the branch and run the FULL suite,
Swift included, before anything merges. A push to main can only ever BE a merge anyway, since
`scripts/hooks/pre-push` refuses a push whose destination is main.
A paths filter was considered instead and REJECTED as unsafe (L88). The job looks like it covers
only the TypeScript importer, but its tests read `docs/prep-runbook.md`,
`docs/scout-extract-runbook.md`, `AGENTS.md`, `package.json` and `fixtures/scout-extract-corpus/`,
and `src/lib/docsCommands.test.ts` asserts that every path AGENTS.md mentions still exists. So
renaming a script anywhere in the tree can turn this job red: its real input set is the whole
repository, a filter would make it skip precisely the change that breaks it, and a skipped job
is indistinguishable from a passing one.

## The committed project file, and the gate that keeps it fresh

The committed `mac/Overture.xcodeproj/project.pbxproj` is generated by xcodegen (see
`docs/contracts.md`), and nothing in CI checks it. `scripts/check-pbxproj-fresh.sh` (#1368) is that
gate: it compares the committed pbxproj against a fresh `xcodegen generate` and BLOCKS on any drift
(a xcodegen version other than `XCODEGEN_PINNED_VERSION` in `scripts/ci-config.sh` says "cannot
verify" rather than a false "stale"). It judges against HEAD, never against the index (#2817): the bare
`git diff` it used until 2026-08-16 compares the working tree to the INDEX, so a regeneration that was
staged and not committed, which is exactly what `scripts/hooks/post-merge` leaves behind, read as FRESH
while the commit a merge would carry was stale. That state was already named in the script's own header
as a BLOCK outcome and was the one state no test had ever built (L151). It now blocks with its own
message, because a staged regen is already in the index and only needs committing, where an unstaged one
still needs staging first.
It also stopped destroying uncommitted work while it looks (#2355). It has to regenerate in order to
compare, which overwrites the working tree, so it now snapshots `mac/Overture.xcodeproj` first and puts
THAT back rather than running `git checkout --`, which restores from the INDEX and so silently discarded
a deliberate uncommitted regeneration. Measured 2026-08-09 during #1571: a regenerated project file was
reverted that way and a new test file consequently sat outside the build for a full suite run that
passed green with those tests absent, and on a FRESH verdict nothing is printed at all, so the loss left
no trace anywhere (L5). A snapshot it cannot take REFUSES (exit 2) rather than regenerating over work it
could not put back. It rides along inside `scripts/test-all.sh`, and both merge
scripts run it: `verify-and-merge-branch.sh` checks BEFORE its worktree regen (the old blind
pre-`xcodegen generate` used to silently rebuild a stale file and ship it), and
`merge-when-green.sh` fetches the branch and checks only when the PR touches the Mac app. The one
path this does NOT structurally cover is a bare `gh pr merge` (the `next-issue` shortcut): a merge
that touches the Mac project MUST go through `scripts/test-all.sh` (then `merge-when-green.sh`) or
`scripts/verify-and-merge-branch.sh`, never a bare `gh pr merge`, or a stale pbxproj can still reach
main.

## Reading the one remaining check before merging

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
