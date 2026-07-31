# Shoot history contract fixtures (#1895, part of #1887)

`v1.json` is the single source of truth for the shoot-history handoff
(`~/Library/Application Support/Overture/overture-shoot-history.json`): every past shoot Dan has
photographed, with its venue and date, so a pitch can say he has shot this room before.

The TS importer (`scripts/import-shoot-history.ts`, via `src/lib/shootHistoryImport.ts`) writes
it from an iCalendar export of Dan's "Shoots" Google Calendar; the app reads it:

- Swift app: `mac/OvertureTests/ShootHistoryContractTests.swift` (via `ShootHistoryFile`).

Code to code on both sides, so it needs no `fixtureShape.ts` entry: that guard exists for the
contracts whose other side is a Claude Code workflow rather than something a test can run. The
precedent here is `overture-history.json`, guarded by its Swift contract test alone.

**Every row is a shape measured in the real export**, not an invented one, because a fixture that
was shaped to make the rule under test fire proves nothing (L48). Read 2026-07-31 from
`Shoots_dan@danwrightphotography.com.ics` (379 events, back to 2018):

- **`venue` carries the calendar's own formatting, unfolded but NOT normalised.** The importer
  deliberately does no venue folding, so this file cannot become a fourth name vocabulary drifting
  from the three the app already has. Two artifacts ride along and the app must fold both:
  - an embedded **newline** instead of a comma (42 of 322 events). This is the one that matters
    most: `VenueNormalization.keyName` splits on the first COMMA, so without folding it the two
    Green Room 42 rows here are two different venues and the count reads 1 instead of 2, on the
    exact room that motivated #1887.
  - a **wrapping double quote** (40 of 322 events), always a matched pair.
- **`date` is the Eastern day, already converted.** The 2018 row is the real 'Round Midnight
  shoot, stored in the calendar as `2018-06-23T01:15Z` and correctly dated 2018-06-22 here. 81 of
  381 events (21%) are evening shows whose UTC day is the next day.
- **Two Abrons rows one day apart** are one opera's dress rehearsal and its performance, the case
  the count's rehearsal-absorption rule exists for.
- **A Carnegie sub-hall** (Weill Recital Hall), which folds to Carnegie Hall through
  `VenuePlaces`.

`title` carries the bracketed presenter where the calendar has one. It is in v1 deliberately: the
count's rehearsal rule and the review card both need it, and adding it later would mean a v2
within weeks.

Four `VEVENT` shapes never reach this file at all, and the importer names each one it refused
rather than guessing: a recurring event (`RRULE`), one changed occurrence of one
(`RECURRENCE-ID`), a cancelled event (`STATUS:CANCELLED`), and an all-day event (no time zone to
date it by). In the real export all seven refusals are meetings or all-day notes with no venue.
