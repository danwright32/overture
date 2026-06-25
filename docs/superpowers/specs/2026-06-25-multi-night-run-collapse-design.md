# Collapse multi-night runs into one prospect (#132)

## Problem

A show that runs several nights surfaces as one prospect per night (real feed: Mark Morris Dance Group ~12 entries, a month-long nightly run would be ~30). Dan pitches the producing org once per run, sends one email, and gets one outcome — so the per-night explosion is queue noise and, worse, has no single place to attach a draft / send / outcome.

## Decision summary (approved 2026-06-25)

- **Storage-level collapse.** Merge a run into a single stored `Prospect` carrying a date range. The run is the unit Dan acts on, so the whole lifecycle (keep/dismiss, draft, send, outcome) lives on one record.
- **Run definition.** Same group + same venue, with performances **within 3 days of each other** (up to 2 dark days) chaining into one run. A larger gap starts a new run.
- **Non-consecutive relation flag.** When the same group+venue produces more than one run (or a run plus separate dates) inside the 90-day window, flag each so Dan sees there may be a longer/related engagement.
- **Opening date drives everything else.** Sorting, outreach timing, past/near-term windowing, and the natural key all key off the run's opening date (consistent with the existing windowing in `QueueView+Model`).

## Components and changes

### 1. Run grouping (new assembly stage, both engines)
A new pure step runs **after** classify+match+`decideProspect` produces per-event prospect rows, **before** upsert. It groups the surviving rows by canonical (group, venue), sorts each group by date, and chains rows whose consecutive gap ≤ 3 days into runs. Each run yields one assembled prospect:
- `performanceDate` = opening date (unchanged field, now "run start")
- `runEndDate` = closing date (new; `nil`/equal for a single night)
- `partOfRelatedRun` = true when another run/date for the same (group, venue) exists in the same batch (new)
- all other fields taken from the opening night's row (fit score, classification, etc. are identical across a run).

Lives as a shared-shape pure function in both `src/lib/` (TS) and `mac/Overture/Domain/` (Swift), kept in parity and unit-tested independently of the network/SwiftData. Undated rows are never merged (each stays its own prospect).

### 2. Schema (`Prospect`, SwiftData)
Add two optional fields: `runEndDate: String?` and `partOfRelatedRun: Bool` (default false). Optional/defaulted, so this is a lightweight automatic migration. Mirror the two fields through the results-file contract (`ResultsFile.swift` / the TS writer) and `QueueItem`.

### 3. Natural key
Unchanged shape — `group | openingDate | venue` — which already uniquely separates two non-consecutive runs of the same group+venue (different opening dates). The existing source-listing-drift re-key path (#29) still recovers a run whose title or opening night shifts between scouts.

### 4. Booking match (`BookingMatch`)
`classify` already tests a single `performanceDate` inside the booking's `[startDate, endDate]`. Generalize to **range overlap**: the run `[performanceDate, runEndDate ?? performanceDate]` overlaps the booking range. No change to the causation/timezone logic (those are #115/#116, out of scope here).

### 5. Display (`QueueView+Model`, row view)
- Date label shows a range ("Jun 25–28") when `runEndDate` differs from the opening date.
- `partOfRelatedRun` renders a quiet note ("This org also performs here on other dates"), like the existing history-flag line.
- Grouping/sorting already key off `performanceDate` (opening), so the windowing/demotion work from this session needs no change.

## Data flow
extract → classify → match → `decideProspect` (per event) → **group into runs (new)** → upsert one prospect per run → queue reads the range + flag.

## Testing
- Run-grouping unit tests (TS + Swift parity): consecutive nights merge; a >3-day gap splits; two separate runs of the same group+venue both set `partOfRelatedRun`; different venues never merge; undated rows never merge; a single night yields `runEndDate == nil`.
- Booking-match: a booking overlapping any night of a run matches; a booking outside the run's range does not.
- Display: range label formatting; related-run note shows only when flagged.
- Full existing Swift + TS suites stay green.

## Out of scope
Booking causation timezone (#116) and venue tiebreaker (#115); cancelled/vanished handling (#133).
