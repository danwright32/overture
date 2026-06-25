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
Add: `runEndDate: String?`, `partOfRelatedRun: Bool` (default false), and `runSourceURLs: [String]` (the member nights' source-listing URLs, for re-recognition per §3; empty for a legacy single-night). Optional/defaulted, so this is a lightweight automatic migration. Mirror the new fields through the results-file contract (`ResultsFile.swift` / the TS writer) and `QueueItem`.

### 3. Natural key and run identity (re-recognition across scouts)
Key shape is unchanged — `group | openingDate | venue` — which uniquely separates two non-consecutive runs of the same group+venue (different opening dates).

**Critical:** the opening night is NOT a stable identity. The feed is windowed to today..+90, so as days pass a run's earliest night drops out and the run's opening date advances. Keying re-recognition on the opening night alone would make an in-progress run look brand new on the next scout, orphaning Dan's keep/dismiss/draft/outcome.

Requirement: a run must be re-recognized by **any of its member performance nights**, not just the opening one. Store the run's member source-listing URLs on the prospect (new `runSourceURLs: [String]`, or reuse the existing per-night source URL set). On upsert, before creating a new prospect, match an assembled run to an existing prospect that shares **any** member source-listing URL; if found, update that record in place (re-keying it to the new opening date) so Dan's decision survives the opening night passing. The existing single-night drift path (#29, `matchByStableSource`) is generalized to this any-night-overlap match.

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
- Run re-recognition (upsert): a run whose opening night has dropped out of the window re-attaches to the existing record (via shared member source URL) and preserves Dan's keep/dismiss, rather than creating a duplicate.
- Booking-match: a booking overlapping any night of a run matches; a booking outside the run's range does not.
- Display: range label formatting; related-run note shows only when flagged.
- Full existing Swift + TS suites stay green.

## Out of scope
Booking causation timezone (#116) and venue tiebreaker (#115); cancelled/vanished handling (#133).
