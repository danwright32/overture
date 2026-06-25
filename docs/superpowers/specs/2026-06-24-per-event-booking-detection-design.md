# Per-event booking detection (#99) — design

## Problem

Overture auto-marks a prospect `booked` when its org name matches a Downbeat
client (`DownbeatBooking.reconcileBooked`). That is org-level: a cold-at-contact
org that books a *different* event later is mis-attributed to this pitch, which
inflates the reported booking rate. Because Dan steers targeting on those
conversion numbers (warm ~79% vs cold ~1.6%), a wrong `booked` is not cosmetic —
it teaches the fit-score loop (#4) the wrong lesson and sends Dan after the wrong
shows. #66 added a relationship-at-send snapshot to stop the worst case; #99 is
the precise fix: match the actual booking event.

## Goals

- Auto-mark `booked` only when there is real proof: a Downbeat booking whose org
  and date (and venue, when known) match the prospect's performance.
- Stop auto-booking on org-name alone. Downgrade that to suggest-and-confirm.
- Keep an honest, auditable booking rate Dan trusts.

## Non-goals

- No change to the scout engine (TypeScript) or the `overture-results.json`
  contract. This is entirely a Mac-app change.
- No change to the Downbeat export contract (already v2, locked in
  `danwright32/downbeat` `.../OvertureExport/CONTRACT.md`).
- Not building the #60 correction UI itself; Phase 1 reuses/links to it.

## Where it lives, and why

Booking detection runs in the Mac app, on the app's launch/save clock
(`ScoutService.runScout` and `RootView.reconcileBookings`), because a booking made
in Downbeat must flip the prospect at next launch without re-running the scout.
The scout runs on a different, manual cadence.

The org identity used for matching is Downbeat's stable `clientId`, never the
display name (per the contract, to avoid repeat-client over-counting). The app
already recomputes the relationship verdict on ingest
(`ScoutService.apply` calls `HistoryMatch.matchRelationship`, whose `MatchVerdict`
carries `downbeatClientId`), but `ProspectAssembler` currently drops it. So the
ID is sourced app-side from the recomputed verdict and persisted on the prospect —
it does **not** ride the scout's results file. This keeps the results schema about
performances, not Downbeat foreign keys, and needs no TypeScript change.

## Behavior

Calibrate aggressiveness to proof, not convenience.

1. **Auto-book** only on an exact booking match (definition below).
2. **Suggest-and-confirm** for everything else: close-but-not-exact dates, ad-hoc
   venue ambiguity, and the old org-name-only heuristic. Surface a "possible
   booking — confirm?" that Dan accepts or rejects through the #60 correction
   surface. Never silently auto-book these.
3. **Never auto-book on org-name alone** once this lands.

### Exact match definition (all must hold)

- **Org:** `booking.clientId == prospect.downbeatClientId`. When the prospect has
  no `downbeatClientId` (the cold-then-booked population #99 targets), fall back
  to a confident `booking.clientDisplayName` ↔ `prospect.groupName` name match
  (`GroupNameMatch.isConfident`) — still only as a candidate that must also pass
  the date check.
- **Date:** `booking.startDate <= prospect.performanceDate <= booking.endDate`,
  as plain `String` comparison on zero-padded `YYYY-MM-DD` (lexicographic ==
  chronological; matches existing `blockedDates` handling). Never `==` (multi-day
  shoots). Guard nil `performanceDate` (no date ⇒ no match).
- **Causation:** `booking.startDate >= the day the pitch was sent`, and the
  prospect must actually have been sent (`sentAt != nil`), not merely approved. A
  booking predating the pitch did not convert it.
- **Venue (soft confirm):** when `booking.venueId` is present, it may strengthen a
  match; for ad-hoc venues (`venueId` omitted) compare on `venueName`
  (canonicalized). Venue is never a *rejecter* of an otherwise-strong org+date
  match, and "both venue fields absent" never counts as agreement.

### Safety guards

- **Monotonic:** auto-booking never auto-reverts. A later run that finds no match
  must not un-book. This protects against a momentarily empty/stale export.
- **Health-gated:** skip reconciliation entirely when the export health is
  `missing` / `unreadable` / `stale` (reuse `DownbeatBridge.Health`). Do not
  reconcile bookings off a bad export.
- **Manual sticky:** `outcomeSourceRaw == .manual` is never overwritten. Preserve
  the existing `already-booked` and `priorRelationshipAtSend == booked`
  short-circuits.
- **1:1:** one booking attributes to at most one prospect. For same-org-same-day
  ambiguity, pick deterministically (closest/contained date, then venue agreement
  when available); otherwise route to suggest-and-confirm rather than guess.

## Data / migration

- Add `var downbeatClientId: String? = nil` to `Prospect` (SwiftData `@Model`).
  Optional + defaulted ⇒ safe automatic lightweight migration, matching every
  prior added field (`priorRelationshipAtSend`, `contactName`, ...). No
  `VersionedSchema` needed (`OvertureApp` uses a plain `Schema([Prospect.self])`).
- Populate it from the recomputed verdict in **both** `ScoutService.make` and
  `ScoutService.apply` so it is set on insert and self-repairs on re-ingest of
  existing prospects.
- Decode the v2 `bookings` array into the Swift `DownbeatExport`
  (`var bookings: [OvertureBooking] = []`), and surface it from
  `loadWithHealth` so reconcile can read it. Depends on #109 (accept export
  version 2) landing first.

## Components touched

- `mac/Overture/Domain/DownbeatExport.swift` — add `OvertureBooking` struct +
  `bookings` on `DownbeatExport`; expose bookings via the load path.
- `mac/Overture/Domain/Prospect.swift` — add `downbeatClientId`.
- `mac/Overture/Domain/ProspectAssembler.swift` — stop dropping
  `verdict.downbeatClientId`; carry it onto the assembled prospect.
- `mac/Overture/Integration/ScoutService.swift` — set the field in `make` and
  `apply`; pass bookings + health into reconcile.
- `mac/Overture/Domain/DownbeatBooking.swift` — the match logic; exact vs
  suggest; all guards.
- `mac/Overture/App/RootView.swift` — the other reconcile entry point.
- (Phase 1 UI) the surface that shows a "possible booking" and the basis of a
  `booked` mark (exact / heuristic / manual), reusing the #60 correction path.

## Phasing

Bookings start empty by contract and fill only from app-made bookings going
forward, so the matcher has little to match early. Sequence for value:

- **Phase 1 (trust fix, no booking-data dependency):** downgrade the org-name
  auto-book to suggest-and-confirm, and make each `booked` show its basis. This
  stops the over-counting now, with data that already exists.
- **Phase 2 (precise matcher):** decode v2 bookings, add `downbeatClientId`, and
  implement the exact-match auto-book with the rule and guards above. Depends on
  #109.

## Testing

Test-first (XCTest/Swift Testing) for every unit:

- Date-range containment: single-day, multi-day, boundary inclusive, nil date.
- Org key: clientId match; confident-name fallback when clientId nil; no match on
  weak name.
- Causation: booking before send rejected; approved-but-not-sent ineligible.
- Monotonicity: a no-match run after a prior booked does not revert.
- Health gating: missing/unreadable/stale export skips reconcile.
- Manual stickiness and the existing short-circuits preserved.
- 1:1 attribution and same-org-same-day tiebreak.
- Migration: existing prospects load with `downbeatClientId == nil`.

## Open risk

The cold-then-booked org only acquires a `clientId` once Overture recognizes it
as a Downbeat client; until then it matches via the name fallback gated by date.
This narrows but does not fully eliminate the "booked a different event" case for
orgs that are clients with two events near the same date — which is exactly why
those route to suggest-and-confirm rather than auto.
