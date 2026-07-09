# Scout runbook

How a scout run produces the prospects the native app surfaces. The scout runs
natively IN the Mac app (the "Run scout" button + the daily auto-run): no browser, no
terminal, no cloud, no TypeScript mirror. Extract, classify, match, rank, and assemble
all happen in `mac/Overture/Domain/` and `mac/Overture/Integration/` (#493 retired the
earlier TypeScript reference pipeline once it was confirmed unused and drifting).

## The loop

1. **Extract (direct Algolia query, no browser).** Carnegie's public calendar
   (`/events`) is a thin front-end over an Algolia search index (`prod_Events`). The
   visible page only renders ~3 days at a time, but the index holds the whole season, so
   the scout queries Algolia directly for the next 90 days in one paginated call instead
   of scraping the DOM. This is a plain HTTPS POST using the public, search-only key the
   site ships in its own client JS (not a secret); no headless browser is involved.
   Implemented in `mac/Overture/Integration/CarnegieExtractor.swift` (+
   `AlgoliaCalendar.swift`). The window opens at midnight New York today and runs 90 days
   out (Eastern, not UTC). At parse time the feed is cleaned: cancelled performances (a
   `Cancelled:` title prefix) are dropped and embedded HTML / zero-width characters are
   stripped from text fields. Output: `ExtractedEvent`s with `title`, `presenter`,
   `venue`, `performanceDate`, `sourceUrl`. If Carnegie rotates the Algolia key or
   restructures the index, `AlgoliaCalendar.swift` is the spot to update.

2. **Classify.** `EventClassifier.swift` rule-classifies every event, assigning the
   ranker's inputs from the fit rules in `PLAN.md` section 4 (summarized below).
   Genuinely ambiguous events are marked `.uncertain` rather than guessed at; they still
   get inserted as prospects, and the review queue (`QueueView`) surfaces any prospect
   where `confidence == uncertain && !confidenceReviewedByDan` for Dan to correct by
   hand via `ClassificationOverride.swift`. There is no automated re-judge pass; an
   earlier Claude-Code-assisted file hand-off for this existed only in the retired
   TypeScript mirror and was confirmed never actually used in practice. The rules
   summary, also useful when manually reviewing an uncertain event:
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
   - `discipline`: dance > opera/theater > music/band/comedy > other (baseline, no signal).
     Choral is not its own category; choir/chorus signals classify as music.
   - `reachable`: true for any venue Dan can reach by transit (section 8).
   - `fit_reason`: one plain sentence, in Dan's terms.

3. **Match + rank + assemble.** Each classified event goes through
   `HistoryMatch.matchRelationship` (repeat-client + DNC against the Downbeat export and
   booking history) and `ProspectAssembler.decide` (drops blocked/suppressed/unreachable,
   scores the rest).

4. **Upsert into the local store.** `ScoutService.apply` upserts the surviving, ranked
   prospects directly into SwiftData by natural key, preserving Dan's keep/dismiss
   decisions. There is no intermediate results file in the live path; `overture-results.json`
   and its importer (`ResultsImporter.swift`) still exist for a manually-produced file, but
   nothing writes one anymore now that the TypeScript mirror is retired.

## Status

- **Extraction: proven live against the Algolia index (2026-06-25).** The direct query
  pulled 83 upcoming events over the 90-day window (clean title/date/venue/presenter/URL),
  with cancelled shows and embedded HTML filtered out.
- **Hands-off trigger: done.** The app runs the scout in-process on the "Run scout"
  button and auto-runs it about daily; it only reads, so it is safe unattended.
- **Trigger 2 (contact-finder + drafter): done.** See `docs/prep-runbook.md`.
- **Still partial:** multi-venue coverage. Carnegie is wired; other venues are not yet
  extracted (offsite venue names resolve via `VenueParser`).
