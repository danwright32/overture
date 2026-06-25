# Per-event booking detection (#99) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-mark a prospect `booked` only when a real Downbeat booking matches its org, performance date (and venue when known); downgrade org-name-only matches to suggest-and-confirm.

**Architecture:** Entirely in the macOS app. Booking detection runs in `DownbeatBooking.reconcileBooked` on the app's launch/save clock. The match keys on Downbeat's stable `clientId`, which the app already computes when it recomputes the relationship verdict on ingest (`ScoutService.apply` → `HistoryMatch.matchRelationship`); the id is persisted on the prospect, never on the scout's results file. The pure match rule is isolated in a testable unit; reconcile applies it with safety guards.

**Tech Stack:** Swift, SwiftData (`@Model`), Swift Testing (`@Test`/`#expect`), xcodegen, xcodebuild.

## Global Constraints

- Mac-app-only: do NOT modify `scripts/scout/run-scout.ts`, `src/lib/*`, or the `overture-results.json` schema.
- Dates are zero-padded `YYYY-MM-DD` day strings compared as plain `String` (lexicographic == chronological). Never `Date`/`DateFormatter` in the match path. Never `==` for the date (use range containment).
- New SwiftData properties MUST be optional or defaulted (lightweight migration); no `VersionedSchema`.
- Org identity for matching is `clientId`, never `clientDisplayName` (name is a gated fallback only).
- Auto-booking is monotonic (never auto-revert) and skipped when export health is `missing`/`unreadable`/`stale`.
- Preserve existing short-circuits in `reconcileBooked`: `outcomeSourceRaw == .manual`, already `.booked`, `priorRelationshipAtSend == booked`.
- After adding any NEW `.swift` file: run `cd mac && xcodegen generate` before `xcodebuild`, or 0 tests run.
- Test command: `cd mac && xcodebuild -scheme Overture -destination 'platform=macOS' test -only-testing:OvertureTests/<Suite>`.

**Dependencies:** Task 1 requires #109 (Mac decoder accepts export version 2) merged into this branch first. Task 7 (suggest-and-confirm UI) requires the #60 correction surface.

---

### Task 1: Decode the v2 `bookings` array

**Files:**
- Modify: `mac/Overture/Domain/DownbeatExport.swift`
- Test: `mac/OvertureTests/DownbeatExportHealthTests.swift`

**Interfaces:**
- Produces: `struct OvertureBooking { let id, clientId, clientDisplayName, shootName, startDate, endDate: String; let venueId: String?; let venueName: String }`; `DownbeatExport.bookings: [OvertureBooking]`.

- [ ] **Step 1: Write the failing test** (append to `DownbeatExportHealthTests`)

```swift
@Test func decodesV2Bookings() throws {
    let json = #"{"version":2,"clients":[],"venues":[],"bookings":[{"id":"B1","clientId":"C1","clientDisplayName":"Every Voice Choirs","shootName":"Spring Gala","startDate":"2026-03-10","endDate":"2026-03-12","venueId":"V1","venueName":"Carnegie Hall"},{"id":"B2","clientId":"C1","clientDisplayName":"Every Voice Choirs","shootName":"Loft Set","startDate":"2026-04-02","endDate":"2026-04-02","venueName":"Pop-up Loft"}],"blockedDates":[]}"#
    let export = try DownbeatBridge.decode(Data(json.utf8))
    #expect(export.bookings.count == 2)
    #expect(export.bookings[0].clientId == "C1")
    #expect(export.bookings[0].endDate == "2026-03-12")
    #expect(export.bookings[1].venueId == nil)        // ad-hoc venue: key omitted
    #expect(export.bookings[1].venueName == "Pop-up Loft")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mac && xcodebuild -scheme Overture -destination 'platform=macOS' test -only-testing:OvertureTests/DownbeatExportHealthTests 2>&1 | grep -iE "decodesV2Bookings|value of type|TEST"`
Expected: FAIL — `DownbeatExport` has no member `bookings`.

- [ ] **Step 3: Add the struct and field**

In `DownbeatExport.swift`, add the struct and the field (default `[]` so a v1 file with no key still decodes):

```swift
struct OvertureBooking: Codable, Equatable, Sendable {
    var id: String
    var clientId: String
    var clientDisplayName: String
    var shootName: String
    var startDate: String
    var endDate: String
    var venueId: String?      // OMITTED for ad-hoc venues; match on venueName then
    var venueName: String
}

struct DownbeatExport: Codable, Equatable, Sendable {
    var version: Int
    var clients: [DownbeatClient]
    var venues: [DownbeatVenue]
    var bookings: [OvertureBooking] = []
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mac/Overture/Domain/DownbeatExport.swift mac/OvertureTests/DownbeatExportHealthTests.swift
git commit -m "Decode the v2 bookings array in the Mac export (#99)"
```

---

### Task 2: Persist `downbeatClientId` on the prospect

**Files:**
- Modify: `mac/Overture/Domain/Prospect.swift` (add property)
- Modify: `mac/Overture/Domain/ProspectAssembler.swift` (stop dropping `verdict.downbeatClientId`)
- Modify: `mac/Overture/Integration/ScoutService.swift` (set in `make` AND `apply`)
- Test: `mac/OvertureTests/MatchingTests.swift`

**Interfaces:**
- Consumes: `MatchVerdict.downbeatClientId: String?` (already produced by `HistoryMatch.matchRelationship`).
- Produces: `Prospect.downbeatClientId: String?`; `AssembledProspect.downbeatClientId: String?`.

- [ ] **Step 1: Write the failing test** — confirm a confident client match persists the id through ingest.

```swift
@Test func ingestPersistsDownbeatClientId() throws {
    let context = try ModelContext(ModelContainer(for: Prospect.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    let client = DownbeatClient(id: "CID-1", displayName: "Every Voice Choirs",
        shortName: nil, email: "a@x.org", contractEmail: "a@x.org",
        phoneNumber: nil, isTaxExempt: nil, hasLeftReview: false,
        specialBehaviors: [], notes: nil, hostingSite: "x.org")
    let event = ExtractedEvent(title: "Every Voice Choirs", venue: "Merkin Hall",
        performanceDate: "2026-03-11", presenter: nil, sourceUrl: "https://x")
    _ = ScoutService.apply(events: [event], clients: [client], history: [],
                           blocked: [], into: context)
    let saved = try context.fetch(FetchDescriptor<Prospect>())
    #expect(saved.first?.downbeatClientId == "CID-1")
}
```

(Verify the `ExtractedEvent` initializer arguments against `mac/Overture/Integration/CarnegieExtractor.swift` before running; adjust field names to match.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mac && xcodebuild -scheme Overture -destination 'platform=macOS' test -only-testing:OvertureTests/MatchingTests 2>&1 | grep -iE "ingestPersistsDownbeatClientId|has no member|TEST"`
Expected: FAIL — `Prospect` has no member `downbeatClientId`.

- [ ] **Step 3: Add the property** in `Prospect.swift` (defaulted optional, lightweight migration):

```swift
    // Downbeat client id from the relationship match, used for per-event booking
    // detection (#99). Defaulted so existing records migrate cleanly.
    var downbeatClientId: String? = nil
```

- [ ] **Step 4: Carry it through the assembler** — in `ProspectAssembler.swift`, where `AssembledProspect` is built from the verdict, add a `downbeatClientId` field on `AssembledProspect` set to `verdict.downbeatClientId` (mirror how `matchedClientName: verdict.matchedClientName` is set).

- [ ] **Step 5: Set it in both ingest paths** — in `ScoutService.swift`, in BOTH `make(_:key:)` and `apply(_:to:)`, set `prospect.downbeatClientId = assembled.downbeatClientId` (mirror the existing `matchedClientName` assignments in each).

- [ ] **Step 6: Run test to verify it passes**

Run the Step 2 command. Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add mac/Overture/Domain/Prospect.swift mac/Overture/Domain/ProspectAssembler.swift mac/Overture/Integration/ScoutService.swift mac/OvertureTests/MatchingTests.swift
git commit -m "Persist downbeatClientId on the prospect through ingest (#99)"
```

---

### Task 3: Pure booking-match rule

**Files:**
- Create: `mac/Overture/Domain/BookingMatch.swift`
- Test: `mac/OvertureTests/BookingMatchTests.swift`
- After creating: `cd mac && xcodegen generate`

**Interfaces:**
- Consumes: `OvertureBooking` (Task 1), `Prospect` fields (`downbeatClientId`, `groupName`, `performanceDate`, `venue`, `sentAt`).
- Produces:
```swift
enum BookingMatchResult: Equatable { case exact, possible, none }
enum BookingMatch {
    static func classify(prospect: Prospect, bookings: [OvertureBooking], clientDisplayNames: [String: String]) -> BookingMatchResult
}
```
`clientDisplayNames` maps `clientId -> displayName` (so a nil-clientId prospect can name-match a booking's `clientDisplayName`).

The rule (exact requires ALL): org key matches (`booking.clientId == prospect.downbeatClientId`, OR — when prospect id is nil — `GroupNameMatch.isConfident(booking.clientDisplayName, prospect.groupName)`); `prospect.performanceDate` non-nil and within `booking.startDate...booking.endDate` (string compare); `booking.startDate >=` the send day AND `prospect.sentAt != nil`; venue agrees when both venue ids/names available (soft — its absence never rejects). A candidate that matches org+date but fails causation or has venue conflict, or that matches org-name weakly, is `possible`. No org/date match is `none`.

- [ ] **Step 1: Write failing tests** (`BookingMatchTests.swift`) — one behavior each:

```swift
import Testing
import Foundation
@testable import Overture

@Suite("Booking match rule")
struct BookingMatchTests {
    private func booking(client: String = "C1", start: String, end: String,
                         venueId: String? = nil, venueName: String = "Hall") -> OvertureBooking {
        OvertureBooking(id: "B", clientId: client, clientDisplayName: "Every Voice Choirs",
            shootName: "", startDate: start, endDate: end, venueId: venueId, venueName: venueName)
    }
    private func prospect(clientId: String? = "C1", date: String? = "2026-03-11",
                          sentDaysAgo: Int? = 30, group: String = "Every Voice Choirs") -> Prospect {
        let p = Prospect(groupName: group, venue: "Hall", performanceDate: date)   // adjust init to real signature
        p.downbeatClientId = clientId
        if let d = sentDaysAgo { p.sentAt = Date(timeIntervalSince1970: 1_700_000_000 - Double(d) * 86_400) }
        return p
    }

    @Test func exactWhenIdAndDateInRangeAndSentBefore() {
        let r = BookingMatch.classify(prospect: prospect(),
            bookings: [booking(start: "2026-03-10", end: "2026-03-12")], clientDisplayNames: ["C1": "Every Voice Choirs"])
        #expect(r == .exact)
    }
    @Test func multiDayBoundaryInclusive() {
        let r = BookingMatch.classify(prospect: prospect(date: "2026-03-12"),
            bookings: [booking(start: "2026-03-10", end: "2026-03-12")], clientDisplayNames: [:])
        #expect(r == .exact)
    }
    @Test func noneWhenDateOutsideRange() {
        let r = BookingMatch.classify(prospect: prospect(date: "2026-03-20"),
            bookings: [booking(start: "2026-03-10", end: "2026-03-12")], clientDisplayNames: [:])
        #expect(r == .none)
    }
    @Test func possibleWhenBookingPredatesSend() {
        let p = prospect(sentDaysAgo: -5)   // sent AFTER the shoot day
        let r = BookingMatch.classify(prospect: p,
            bookings: [booking(start: "2026-03-10", end: "2026-03-12")], clientDisplayNames: [:])
        #expect(r == .possible)
    }
    @Test func noneWhenNeverSent() {
        let r = BookingMatch.classify(prospect: prospect(sentDaysAgo: nil),
            bookings: [booking(start: "2026-03-10", end: "2026-03-12")], clientDisplayNames: [:])
        #expect(r == .none)
    }
    @Test func nilDateNeverMatches() {
        let r = BookingMatch.classify(prospect: prospect(date: nil),
            bookings: [booking(start: "2026-03-10", end: "2026-03-12")], clientDisplayNames: [:])
        #expect(r == .none)
    }
    @Test func nameFallbackWhenClientIdNil() {
        let r = BookingMatch.classify(prospect: prospect(clientId: nil),
            bookings: [booking(start: "2026-03-10", end: "2026-03-12")],
            clientDisplayNames: ["C1": "Every Voice Choirs"])
        #expect(r == .exact)   // confident name + date in range + sent before
    }
}
```

(Adjust `Prospect`/`ExtractedEvent`/`OvertureBooking` initializer calls to the real signatures before running.)

- [ ] **Step 2: Run to verify they fail** — `... -only-testing:OvertureTests/BookingMatchTests`. Expected: FAIL (no `BookingMatch`).

- [ ] **Step 3: Implement `BookingMatch.swift`** to satisfy exactly these tests: range containment via `>=`/`<=` string compare; nil date ⇒ `.none`; never-sent ⇒ `.none`; booking-before-send ⇒ `.possible`; id match or confident-name fallback for org; everything that matches org+date+causation ⇒ `.exact`, org+date but failed causation ⇒ `.possible`, else `.none`.

- [ ] **Step 4: `cd mac && xcodegen generate`** (new file), then run Step 2 command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mac/Overture/Domain/BookingMatch.swift mac/OvertureTests/BookingMatchTests.swift mac/project.yml mac/Overture.xcodeproj
git commit -m "Add the pure per-event booking match rule (#99)"
```

---

### Task 4: Apply the rule in `reconcileBooked` with guards

**Files:**
- Modify: `mac/Overture/Domain/DownbeatBooking.swift`
- Modify: `mac/Overture/Integration/ScoutService.swift` and `mac/Overture/App/RootView.swift` (pass bookings + health into reconcile)
- Test: `mac/OvertureTests/DownbeatBookingTests.swift`

**Interfaces:**
- Consumes: `BookingMatch.classify(...)`, `OvertureBooking`, `DownbeatBridge.Health`.
- Produces: extended `reconcileBooked(prospects:clients:bookings:health:now:)` that auto-books only on `.exact`, marks `.possible` as a suggestion (set a `bookingSuggested` flag — add as defaulted `Bool = false` on `Prospect`), books nothing when health is not `.ok`, and never reverts.

- [ ] **Step 1: Write failing tests** in `DownbeatBookingTests.swift`: (a) an exact match auto-books a contacted prospect; (b) a possible match does NOT auto-book but sets `bookingSuggested`; (c) reconcile with `health != .ok` books nothing; (d) a previously auto-booked prospect with no match this run stays booked (monotonic); (e) a `.manual` outcome is untouched. Use the in-memory `ModelContext` pattern from Task 2.

- [ ] **Step 2: Run to verify they fail** — `... -only-testing:OvertureTests/DownbeatBookingTests`. Expected: FAIL.

- [ ] **Step 3: Add `var bookingSuggested: Bool = false` to `Prospect`**, then extend `reconcileBooked` to take `bookings:` and `health:`, guard `health == .ok`, call `BookingMatch.classify`, auto-book on `.exact` (set `outcome`, `outcomeSourceRaw = .auto`, `outcomeAt`), set `bookingSuggested = true` on `.possible`, keep all existing short-circuits, and never clear an existing booked outcome. Stop auto-booking on the old org-name path (that becomes `.possible` via the name fallback).

- [ ] **Step 4: Update callers** — `ScoutService.runScout` and `RootView.reconcileBookings` pass `loaded.bookings` (expose `bookings` from `loadWithHealth`) and `loaded.health`.

- [ ] **Step 5: Run to verify they pass.** Expected: PASS. Then full suite: `cd mac && xcodebuild -scheme Overture -destination 'platform=macOS' test` — all green.

- [ ] **Step 6: Commit**

```bash
git add mac/Overture/Domain/DownbeatBooking.swift mac/Overture/Domain/Prospect.swift mac/Overture/Integration/ScoutService.swift mac/Overture/App/RootView.swift mac/OvertureTests/DownbeatBookingTests.swift
git commit -m "Auto-book only on exact match, suggest otherwise, with guards (#99)"
```

---

### Task 5 (gated on #60): Surface suggestions and the booked basis

**Files:** the review UI (`mac/Overture/UI/...`) and the #60 correction surface.

The `bookingSuggested` flag and the outcome source (`auto`/`manual`) now exist on the prospect. Surface a "possible booking — confirm?" affordance that confirms (sets `.booked`, `outcomeSourceRaw = .manual`) or dismisses (clears `bookingSuggested`), and show the basis of any `booked` mark (exact match vs your hand). Reuse the #60 correction interaction so a confirmation sticks and is never overwritten by a later scout run. Detailed steps to be written once #60's surface exists.

---

## Self-Review

- **Spec coverage:** exact-match auto / suggest-else (Tasks 3-4), no auto on org-name alone (Task 4 Step 3), clientId via SwiftData not results (Task 2), v2 bookings decode (Task 1), date string range (Task 3), causation + monotonic + health gate + manual sticky (Tasks 3-4), migration optional field (Tasks 2-4), suggest UI + basis (Task 5, gated on #60). 1:1 same-org-same-day tiebreak: fold into Task 4 Step 3 (when >1 booking classifies `.exact` for one prospect, pick the contained-date one; if still tied, downgrade to `.possible`) — add a test in Task 4 Step 1.
- **Placeholder scan:** Task 5 is intentionally deferred (external #60 dependency) and labeled as such, not a hidden placeholder.
- **Type consistency:** `downbeatClientId` (Task 2) consumed in Task 3; `BookingMatchResult`/`classify` (Task 3) consumed in Task 4; `OvertureBooking` (Task 1) consumed in Tasks 3-4.
