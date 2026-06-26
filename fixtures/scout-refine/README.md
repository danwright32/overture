# Scout refine contract fixtures (#159)

These two files are the single source of truth for the scout <-> refine-agent round trip, the
fourth cross-boundary contract (#157 covered the other three). They guard the same silent-drift
risk (the #109 / #113 class of bug):

- `uncertain.json` is the work-list the scout WRITES
  (`~/Library/Application Support/Overture/overture-uncertain.json`, via `buildUncertainPayload` in
  `src/lib/refineContract.ts`): only the events the rules left `uncertain`, each with the rules'
  best guess, for the agent to re-judge.
- `refined.json` is what the **Claude Code scout agent** (`docs/scout-runbook.md`) WRITES back
  (`overture-refined.json`); the scout READS it via `applyRefinements`
  (`src/lib/refineClassifications.ts`) on the next run.

The agent is the counterpart side with no automated test, so these committed fixtures are its spec.
`src/lib/refineContract.test.ts` asserts the writer produces `uncertain.json` exactly, that the
reader folds `refined.json` back correctly (including the `fit_reason` fallback and leaving
already-confident events untouched), and the join-key integrity: every `title` in `refined.json`
was handed out in `uncertain.json`. The `title` is that opaque join key the agent must echo verbatim.
