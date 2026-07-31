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
- `sampleCompliantOutput`: a hand-written `PrepResults` that satisfies `expected`. The always-on tests
  assert it passes; the real-AI harness uses it as a reference of a correct answer.
  It must satisfy the runbook AS IT STANDS, not as it stood when the fixture was typed (#1872). Nothing
  re-reads these when a rule lands, and the drift runs the way that hides problems: nine samples drafted
  without saying what the show is, long after #1824 required it, and every one still self-checked clean.
  A test now asserts each drafting entry either says what the show is or says why it cannot, so when you
  add a runbook rule, update every sample in the same change. Where a fixture's item carries no
  `showListing` at all, the honest answer is `showSummaryAbsentReason: "no_listing_page"`, never a summary
  written from the sources: a sample that invents one teaches the eval to accept an invented answer.

## The two layers

1. Always-on, free (runs on every `pnpm test`):
   - `src/lib/prepRunbookRules.test.ts`: asserts each guarded rule stays present in the runbook text.
   - `src/lib/prepEval.test.ts`: scores recorded/mock outputs against these fixtures, proving the engine
     both passes a compliant output and flags each way a regression could produce a bad one.
2. On-demand, real AI, opt-in, spends tokens (never in CI):
   - `scripts/eval-prep-runbook.sh --yes` runs the CURRENT runbook against each fixture through the same
     headless `claude -p` mechanism the app uses, then scores the actual output with the SAME engine
     (`scripts/eval-prep-runbook.ts` -> `src/lib/prepEval.ts`). Run it by hand before shipping a runbook edit.
     Each real run KEEPS what it produced, in a dated directory under `.overture-eval-runs/` (last 10, and a
     directory renamed off that shape is never pruned). Read a failure's own output there rather than paying
     to produce it again; the run prints the path when it finishes.

## Rules covered

- `host-venue-not-target`: the target is the act, never the host venue (#366/#368).
- `carnegie-citywide-press-inbox`: a press/PR inbox is disqualified at any confidence (#635).
- `self-produced-duo-both-performers`: a self-produced duo surfaces BOTH named performers (#366/#634).
- `no-organiser-named-act-pursued`: a listing naming no producer is researched through the people it does
  name, and nobody is labelled `presenter` (#1856).
- `five-named-performers-none-dropped`: the same route with a FIVE name bill, where there is no headcount
  ceiling and the two performers with nothing findable are still surfaced at low confidence (#1817).
- `stale-site-misnamed-co-performer`: a stale site's misnamed co-performer is flagged (kept low), not dropped.
- `presenter-not-venue`: the act's own form outranks a venue inbox; a real presenter is additive, never the venue.
- `already-covered-photographer`: an explicit "we have a photographer" statement sets the fit-risk note (#611).
- `returning-client-booked`: a booked returning client opens warm, with no cold self-introduction and no portfolio/gallery scaffolding (#1215).
- `returning-client-warm-lead`: a warm lead drops the cold self-introduction but keeps one light credential and the portfolio link (#1215).
- `listed-house-is-refused`: an organisation on the queue's `houses` list is the building, so its addresses are disqualified even when the listing calls it the presenter (#1720/#1723).
- `solo-artist-cabaret-not-an-organisation`: the run says back what the listing says the show IS, and describes Dan without categorizing the recipient (#1824).
- `season-calendar-describes-no-show`: the same listing text, read, that describes no show at all. The honest answer is `no_description_published`, never a description assembled from the neighbouring listings (#1824).

### Where the #1824 pair's shape comes from (L48)

Both carry a `showListing` inside their `input`, which is what the app now hands the run. Their page text is
shaped from a MEASURED page, not invented to make the rule fire: the Green Room 42 listing behind the
2026-07-30 draft (`thegreenroom42.venuetix.com/showdetails/...`), rendered on 2026-07-30, carries 1,994
characters of visible text in total, in this order: nav bar, artist name, show title, an "About the Show"
paragraph naming the form outright ("a cabaret concert of new songs written by..."), a Featuring list of
five, Genre and Duration and Age Restriction, a street address, similar and related shows, and a footer
carrying the room's two addresses. A plain download of the same URL returns an 11KB shell containing zero
occurrences of "cabaret". The fixture reproduces that structure with invented names and `.example` domains,
per the no-real-PII rule above; the calendar fixture reproduces the OTHER shape a `sourceListingURL` reaches
(a season index), which about a third of the store's listing URLs point at.

## What this harness CANNOT test, and why no fixture should pretend otherwise (#1723)

The house rule (#1720) has two halves. Only one of them is testable here.

**Testable: refusing a listed house.** `listed-house-is-refused` carries an optional run-level `houses`
list, which `scripts/eval-prep-runbook.sh` puts in the prompt when a fixture has one. Everything the
verdict depends on is inline, so the fixture discriminates: drop the rule and the run emits Harbour Arts
Centre as a `presenter` contact, which the expectation forbids. It can genuinely go red.

**NOT testable: following the trail to an organisation the run has not visited.** The other half of the
rule says an organisation NOT on the list must be FETCHED at its own site before the run may conclude no
contact exists. This harness cannot check that, and the reason is structural rather than a gap to fill
later: `eval-prep-runbook.sh` passes `"Bash Edit WebFetch WebSearch Skill"` as the FORBIDDEN tool list
(the third argument of `claude_run_scope`, see `mac/scripts/lib/claude-run-scope.sh`) and hands the run
all its material inline, deliberately, so the eval is reproducible and carries no real PII. A run that
cannot fetch anything cannot demonstrate that it followed a trail, and a fixture that supplied the
destination inline would be handing over the very thing the rule is about.

So a "the run visited the named organisation" fixture would pass on the day it was written and could
never fail. **Do not add one.** It would read as coverage of the behaviour that actually broke on the
Abrons night (#1681) while testing nothing at all. The fetching half is covered instead by the
`RUNBOOK_RULES` presence guard in `src/lib/prepRunbookRules.ts`
(`named-organisation-must-be-visited`), which proves the instruction is still in the prompt, and by
reading what a real Prep run actually did.
