# prep-eval fixtures (#591)

Regression fixtures for the prep-runbook's research/drafting JUDGMENT (`docs/prep-runbook.md`). The
runbook is a prompt executed as a headless AI run, not code, so its rules have no compiler behind them.
Each fixture here pairs an input listing with the rule outcome its produced draft must satisfy.

These are NOT one of the JSON handoff contracts in `docs/contracts.md` (they are never read by the app);
they are test fixtures for the two-layer harness built for #591. Everything here is synthetic: no real
person, org, venue, or email address. `.example` domains and made-up names throughout.

## Shape of one fixture

- `name` / `rule`: the fixture id and the one runbook rule it targets.
- `input`: a single prep-queue-style work-list item (`naturalKey`, `groupName`, `venue`, `discipline`,
  `production`, ...).
- `sources[]`: the representative page material the run is allowed to research from (label, url, content).
  The real-AI harness tells the run to use ONLY this, so the eval scores the runbook's judgment on fixed
  material rather than the drift of live sites.
- `expected`: the rule outcome the produced `PrepResults` must satisfy (`PrepEvalExpectation` in
  `src/lib/prepEval.ts`): forbidden inboxes/domains/patterns, required performers, provenance rules,
  confidence rules, presenter/note requirements, the discipline gallery link.
- `sampleCompliantOutput`: a hand-written `PrepResults` (v6) that satisfies `expected`. The always-on
  tests assert it passes; the real-AI harness uses it as a reference of a correct answer.

## The two layers

1. Always-on, free (runs on every `pnpm test`):
   - `src/lib/prepRunbookRules.test.ts`: asserts each guarded rule stays present in the runbook text.
   - `src/lib/prepEval.test.ts`: scores recorded/mock outputs against these fixtures, proving the engine
     both passes a compliant output and flags each way a regression could produce a bad one.
2. On-demand, real AI, opt-in, spends tokens (never in CI):
   - `scripts/eval-prep-runbook.sh --yes` runs the CURRENT runbook against each fixture through the same
     headless `claude -p` mechanism the app uses, then scores the actual output with the SAME engine
     (`scripts/eval-prep-runbook.ts` -> `src/lib/prepEval.ts`). Run it by hand before shipping a runbook edit.

## Rules covered

- `host-venue-not-target`: the target is the act, never the host venue (#366/#368).
- `carnegie-citywide-press-inbox`: a press/PR inbox is disqualified at any confidence (#635).
- `self-produced-duo-both-performers`: a self-produced duo surfaces BOTH named performers (#366/#634).
- `stale-site-misnamed-co-performer`: a stale site's misnamed co-performer is flagged (kept low), not dropped.
- `presenter-not-venue`: the act's own form outranks a venue inbox; a real presenter is additive, never the venue.
- `already-covered-photographer`: an explicit "we have a photographer" statement sets the fit-risk note (#611).
- `returning-client-booked`: a booked returning client opens warm, with no cold self-introduction and no portfolio/gallery scaffolding (#1215).
- `returning-client-warm-lead`: a warm lead drops the cold self-introduction but keeps one light credential and the portfolio link (#1215).
