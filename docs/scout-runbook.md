# Scout runbook

How a scout run produces the prospects the native app surfaces. The live scout runs
natively IN the Mac app (the "Run scout" button + the daily auto-run): no browser, no
terminal, no cloud. The classify -> match -> rank -> assemble brain is the tested
engine, ported to Swift in `mac/Overture/Domain/`. The TypeScript path
(`scripts/scout/run-scout.ts`) mirrors it and writes a results file for reference, but
the app's own scout is the live one.

## The loop

1. **Extract (direct Algolia query, no browser).** Carnegie's public calendar
   (`/events`) is a thin front-end over an Algolia search index (`prod_Events`). The
   visible page only renders ~3 days at a time, but the index holds the whole season, so
   the scout queries Algolia directly for the next 90 days in one paginated call instead
   of scraping the DOM. This is a plain HTTPS POST using the public, search-only key the
   site ships in its own client JS (not a secret); no headless browser is involved.
   Implemented in `mac/Overture/Integration/CarnegieExtractor.swift` (+
   `AlgoliaCalendar.swift`) for the app and mirrored in `src/lib/algoliaCalendar.ts`
   (`fetchCalendar`, `WINDOW_DAYS = 90`) for the TS path. The window opens at midnight
   New York today and runs 90 days out (Eastern, not UTC). At parse time the feed is
   cleaned: cancelled performances (a `Cancelled:` title prefix) are dropped and embedded
   HTML / zero-width characters are stripped from text fields. Output: `ExtractedEvent`s
   with `title`, `presenter`, `venue`, `performanceDate`, `sourceUrl`. If Carnegie
   rotates the Algolia key or restructures the index, `AlgoliaCalendar` is the spot to
   update.

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

- **Extraction: proven live against the Algolia index (2026-06-25).** The direct query
  pulled 83 upcoming events over the 90-day window (clean title/date/venue/presenter/URL),
  with cancelled shows and embedded HTML filtered out.
- **Hands-off trigger: done.** The app runs the scout in-process on the "Run scout"
  button and auto-runs it about daily; it only reads, so it is safe unattended.
- **Trigger 2 (contact-finder + drafter): done.** See `docs/prep-runbook.md`.
- **Still partial:** multi-venue coverage. Carnegie is wired; other venues are not yet
  extracted (offsite venue names resolve via `VenueParser`).
