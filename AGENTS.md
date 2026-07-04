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

- Engine: `pnpm test`, `pnpm typecheck`. Scripts: `pnpm export` (write results handoff),
  `pnpm seed`, `pnpm import-history`.
- Mac app: `cd mac && xcodegen generate`, then `./scripts/run-tests-locked.sh` (wraps
  `xcodebuild -scheme Overture -destination 'platform=macOS' test` in a lock so it can't
  collide with another test run on this Mac; use it instead of raw `xcodebuild test`).

The pieces hand off through fixed-shape JSON files, not direct calls. `docs/contracts.md`
catalogs every one (writer, reader, version, and its `fixtures/` guard); read it before changing
any cross-boundary file shape.
