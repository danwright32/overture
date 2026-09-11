# Building and running the app

Looking at the app, installing a Release build, the signing identity, and reclaiming what the builds leave behind.

A body file for `AGENTS.md`, which carries the one line form of every rule below plus a pointer
here. The index line is enough to tell you a rule APPLIES; it is not enough to apply it, because
the measurement it came from lives here. Read the entry before the rule decides anything.

## Reclaiming Xcode's build output

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

## Looking at the app

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
  Signing reads the USER's keychain search list, which is a persistent OS resource shared with every
  other tool on this Mac, and something once left a THROWAWAY keychain under a temp directory in it
  (#2611). `mac/scripts/prune-stale-keychains.sh` removes any entry whose file is gone and keeps
  every entry that exists, in the order it was in; `--dry-run` reports and changes nothing. It is
  deliberately NOT in `scripts/test-all.sh`, unlike the two advisories that ride along there: those
  read or clear something this repo created, while this WRITES a list shared with the whole machine,
  so it stays behind a command somebody typed. It refuses outright when no entry survives, because
  an unreadable listing and an empty list look identical and the only way to change the list is to
  write the whole of it back. If a fixture ever needs its own keychain it must pass it by
  `--keychain` scope; a guard in `mac/scripts/prune-stale-keychains.test.sh` fails if any `*.test.sh`
  writes the search list instead.

## Installing a Release build, and what the Update button runs

- `build-install.sh` builds WHATEVER IS CHECKED OUT, which is what you want when installing a branch build
  deliberately. The freshness panel's Update button does NOT run it directly: it runs
  `mac/scripts/update-overture.sh`, which brings the checkout up to origin/main first and only then
  installs, refusing (and installing nothing) when it cannot do that safely. Pressing Update means "get me
  what has shipped"; running the installer by hand means "build this". They were the same command until
  2026-08-04, and Dan hit the loop that follows from it: the panel compares the installed commit against
  origin/main, so a checkout parked on an already-merged branch reinstalled the same commit and stayed
  behind forever.
  **Since #2923 the ONLY move it will make is fast-forwarding main onto its own remote**, and that is the
  paragraph to read before changing it. It used to switch a checkout standing anywhere else onto main, and
  on 2026-08-17 it did that to a working checkout in the middle of a session, off an in-progress feature
  branch, silently. The cost was not the inconvenience: the `scripts/test-all.sh` run made straight
  afterwards verified main while everyone believed it was verifying the branch, and that pass was written
  into a PR body as evidence for code it had never compiled; the `git push -u origin <branch>` after it
  pushed main's HEAD at the feature branch's name and was refused only by luck of the ref ordering. So the
  three refusals are now uncommitted work, a local main the remote does not contain, and **HEAD standing
  anywhere other than main**, each with its own sentence in the Terminal and in the app's panel, and the
  last of them naming the branch it left alone. What that gives up is the automatic rescue of the parked
  checkout above: telling a parked branch from a live one cannot be done cheaply or honestly (a
  squash-merged branch is neither an ancestor of main nor patch-equal to it, so "already shipped" needs
  `gh`, and even a branch carrying nothing of its own may be one a session is standing in). The loop it
  leaves is LOUD rather than silent, which is the difference that mattered.
  A corollary for anyone working here, and it is now what clears that refusal: leave the checkout on main
  when you finish, because a session that parks it on a branch is what puts the Update button in front of
  that state.
  The same issue covered the CLASS rather than that one instance. `scripts/lib/worktree-safety.sh` holds
  one answer to "is this directory mine to scrub", and both remaining places that move a checkout's HEAD
  ask it before they touch anything: `setup_worktree` in `scripts/verify-and-merge-branch.sh` (which
  force-detaches the verify slot, runs `git clean -ffdx` over it and on its fallback path deletes the
  directory outright, at a path that comes from `OVERTURE_VERIFY_WORKTREE`) and
  `gate_branch_project_freshness` in `scripts/lib/project-freshness.sh` (which walks a caller's directory
  through every ref it is given and restores it to a bare SHA). It tells them apart by evidence rather
  than by a name: the verify slot is created with `worktree add --detach` and is detached for its whole
  life, so a directory standing on a NAMED branch is somebody's working checkout, whatever it is called.
  It asks that independently of "is this the checkout I am running from", so neither side answers for the
  other.

