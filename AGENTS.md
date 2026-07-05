# Overture

Overture finds performing arts performances worth pitching for Dan Wright Photography,
ranks them by fit, and surfaces them for Dan to review, keep, and (later) approve a
drafted email. See `PLAN.md` for the full product plan.

This repository holds two pieces:

- **The scout engine** (`src/lib/`, `scripts/`): TypeScript, run with `tsx` and tested
  with `vitest`. Pure, deterministic qualification logic (ranker, repeat-client
  matcher, prospect assembly) plus the scripts that read the Downbeat client/venue
  export, import booking history, and write the results handoff file. The agentic
  scouting/contact-finding/drafting runs as a Claude Code workflow on Dan's Max plan.
- **The native macOS app** (`mac/`): a SwiftUI app (the review surface Dan lives in),
  generated with `xcodegen` from `mac/project.yml`. It owns a local SwiftData store and
  ingests the results file the engine writes, the same fire-and-forget file boundary
  Downbeat uses for its export. Mirrors Downbeat's structure and conventions; keeps
  Overture's own forest-green and gold brand.

The earlier Next.js web dashboard was retired once Dan chose a native Mac app.

## Working here

- Engine: `pnpm test`, `pnpm typecheck`, `pnpm import-history <csv-path>` (one-shot booking
  history import, see `docs/import-history.md`). `pnpm scout [events.json]` mirrors the
  live scout in TypeScript and writes a reference results file (see
  `docs/scout-runbook.md`); the real scout runs natively in the Mac app.
- Mac app: `cd mac && xcodegen generate`, then `./scripts/run-tests-locked.sh` (wraps
  `xcodebuild -scheme Overture -destination 'platform=macOS' test` in a lock so it can't
  collide with another test run on this Mac; use it instead of raw `xcodebuild test`). A
  scoped `-only-testing:OvertureTests/<Suite>/<test>` run can print
  `** TEST SUCCEEDED **` with 0 tests executed if the path doesn't match anything (for
  example a `@Suite("...")` display name that differs from its Swift type name),
  indistinguishable at a glance from a real pass. Confirm a scoped run by grepping its
  output for the specific test name, or just run the full suite via
  `run-tests-locked.sh`, which completes in a few seconds.
- Running multiple Claude agents on this repo at once: give each agent its own git
  worktree so file edits and branches never collide, but xcodebuild itself must stay
  serialized across all of them. `run-tests-locked.sh`'s lock file lives at one fixed
  path outside any checkout, so every worktree (and CI) contends for the same lock
  instead of each locking its own copy. The current verification model is a hybrid:
  each agent builds and tests its own worktree under that shared lock and stops after
  opening a PR (it never merges and never launches the live app); the coordinating
  session then independently re-runs the full suite on every branch under the same
  lock before merging, rather than trusting each agent's self report.

The pieces hand off through fixed-shape JSON files, not direct calls. `docs/contracts.md`
catalogs every one (writer, reader, version, and its `fixtures/` guard); read it before changing
any cross-boundary file shape.

## CI status before merging

A pending check and a stuck one look identical in GitHub's PR view. Do not merge a PR on
the strength of "the check hasn't failed yet"; the `swift-tests` check needs to have
actually shown a pass, not just an absence of failure so far. Before merging, run
`scripts/check-pr-ci.sh <pr-number>`. It reports every check's real state and, for
`swift-tests` specifically, tells a check that is genuinely still working apart from one
that is stalled because the self-hosted runner is unreachable or has stopped picking up
jobs. `scripts/merge-when-green.sh <pr-number>` wraps that same check in a poll loop and
only merges once it reports a genuine pass; it stops without merging on a real failure, a
stalled check, or its own timeout.
