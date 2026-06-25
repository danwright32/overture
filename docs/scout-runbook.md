# Scout runbook

How a scout run produces the results file the native app ingests. The scout is a
Claude Code workflow on Dan's Max plan (not a paid API), triggered by Dan. It uses
Claude Code's own browser tools; nothing here is a standalone server.

## The loop

1. **Extract (browser).** For each watched venue, open its calendar in the headless
   browser and run the venue's extractor in the page. Carnegie: navigate to
   `https://www.carnegiehall.org/Calendar` and evaluate
   `scripts/scout/extract-carnegie.js`. Carnegie's calendar is JS-rendered and
   bot-protected, so a plain fetch will not work; it must run in a real browser.
   Output: events with `date`, `title`, `venue` (in `context`), `presenter`, `sourceUrl`.

2. **Classify (rules first, then refine the unsure slice).** `run-scout.ts` rule-classifies
   every event for free (`classifyEvent`), assigning the ranker's inputs from the fit rules in
   `PLAN.md` section 4 (summarized below). It flags genuinely ambiguous events `uncertain` and
   writes just those to `~/Library/Application Support/Overture/overture-uncertain.json`, each
   with the rules' best guess. **You (the Claude step) re-judge only that uncertain slice (#30)**
   — read the file, decide `production` / `profile` / `coverage` / `discipline` for each using
   the same rules plus your judgment (e.g. a self-presented orchestra that is actually already
   covered), and write the results as `overture-refined.json` (an array of
   `{title, production, profile, coverage, discipline, fit_reason?}`). Re-run `run-scout.ts`; it
   merges the refinements over the rules output and marks those events confident. Refining only
   the unsure slice keeps cost near zero. The rules summary you also apply when refining:
   - `production`: `agency` when presenter is a tour operator / management / a
     "International Competition Winners" or "Rising Stars" showcase rental; `self`
     when the presenter is the performing group itself (a choir, school, ensemble,
     small company); else `unknown`.
   - `profile`: `strong` for choirs, music schools/academies, youth/community
     ensembles, small opera/theater companies; `weak` for competition-winner /
     prestige-soloist showcase rentals; else `neutral`.
   - `coverage`: `likely_uncovered` for small self-produced shows (e.g. Weill
     recitals); `likely_covered` for Stern mainstage prestige / big touring acts; else
     `unknown`.
   - `discipline`: dance > opera/theater > choral/band/comedy > music (baseline).
   - `reachable`: true for any venue Dan can reach by transit (section 8).
   - `fit_reason`: one plain sentence, in Dan's terms.

3. **Match + rank + assemble (TS foundation).** Feed each classified event through
   `matchRelationship` (repeat-client + DNC against the Downbeat export and booking
   history) and `decideProspect` (drops blocked/suppressed/unreachable, scores the
   rest). This is the tested engine in `src/lib/`; do not re-implement it.

4. **Write the results file.** Emit the surviving, ranked prospects as
   `~/Library/Application Support/Overture/overture-results.json` (the format in
   `scripts/scout/run-scout.ts` and `mac/.../Domain/ResultsFile.swift`). The Mac app
   ingests it, upserting by natural key so Dan's keep/dismiss decisions are preserved.

## Status

- **Extraction: proven against the live site (2026-06-22).** The DOM extractor pulls
  clean structured events (title, date, venue, presenter, URL) from the live,
  bot-protected Carnegie calendar through the headless browser.
- **Still to build:** the hands-off trigger (Dan presses "Fetch latest scout" in the
  app, which drops a request file a watcher consumes), multi-venue coverage, and the
  contact-finder + drafter stages (Trigger 2).
