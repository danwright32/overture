import Testing
import Foundation
import SwiftData
@testable import Overture

// #986, through the REAL ingest, because the count and the WIRE that records it are two separate claims.
// SourcePlacement.placedCount can be perfect while the ingest never folds it into the source, and every
// unit test would still pass while the stored value stayed zero. That exact cut has gone unnoticed in this
// repo before: #887's guard stayed green across 1,829 tests with its wire cut.
//
// The count also has to SURVIVE the run that produced it: #970's drift detection compares this run against
// whether the source had EVER placed, so the fact has to persist on the row, not live only in the seconds
// after a scout. (#1029 removed the Dan-facing sentence this used to feed; the recorded count stays.)
@MainActor
@Suite("A source remembers whether its shows said where they are (#986)")
struct SourcePlacementPersistenceTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func source(_ ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: "smokering", orgName: "Smoke Ring Quartet",
                              listingsURL: "https://smokering.example/dates", kind: .html)
        s.pendingContentHash = "new-hash"
        s.hasUnreadChanges = true
        ctx.insert(s)
        return s
    }

    // Every event carries a venue, so none is rejected: this suite is about `location`, not readability.
    private func event(_ title: String, location: String?) -> ScoutExtractEvent {
        ScoutExtractEvent(title: title, presenter: title, venue: "Under St Marks",
                          performanceDate: "2099-10-01",
                          sourceUrl: "https://smokering.example/\(title)",
                          location: location)
    }

    private func ingest(_ events: [ScoutExtractEvent], into ctx: ModelContext) {
        let r = ScoutExtractResults(
            version: 2, generatedAt: "2026-07-16T00:00:00Z",
            results: [ScoutExtractResult(sourceId: "smokering", verdict: .upcomingListings,
                                         events: events, note: nil)])
        ScoutExtractIngest.ingest(r, clients: [], history: [], blocked: .empty,
                                  today: ScoutTestClock.beforeAllFixtures,
                                  now: Date(timeIntervalSince1970: 1_800_000_000), into: ctx)
    }

    // The artist page, which is what the whole #970 gate is for. A run that says where the shows are is
    // remembered as having done so.
    @Test func aRunThatSaysWherePlacesRecordsIt() throws {
        let ctx = try context()
        let s = source(ctx)

        ingest([event("Louisville", location: "Louisville, KY"),
                event("Brooklyn", location: "Brooklyn, NY")], into: ctx)

        #expect(s.lastPlacedCount == 2)
        #expect(s.hasEverPlaced == true)
    }

    // The venue calendar: FRIGID's real shape. It has never said where a show is, it does not now, and it is
    // silent. ~30 of the 38 watched sources are this, and a line on each is a line Dan learns to skim.
    @Test func aVenueCalendarThatNeverSaysWhereStaysSilent() throws {
        let ctx = try context()
        let s = source(ctx)

        ingest([event("Honey, Drop It", location: nil),
                event("Open Mic", location: nil)], into: ctx)

        #expect(s.lastPlacedCount == 0)
        #expect(s.hasEverPlaced == false)
    }

    // THE failure path, end to end through the real ingest. A source that said where its shows were, and now
    // says nothing, has drifted, and the geographic gate is off for it. This is the case #986 exists for, and
    // the one a bare "placed N of M" could never tell apart from the venue calendar above. The recorded state
    // is what #970's drift detection reads: it placed before (hasEverPlaced) but placed nothing this run.
    @Test func aSourceThatStopsSayingWhereRemembersItPlacedBefore() throws {
        let ctx = try context()
        let s = source(ctx)

        ingest([event("Louisville", location: "Louisville, KY"),
                event("Brooklyn", location: "Brooklyn, NY")], into: ctx)
        #expect(s.hasEverPlaced == true)

        // The same source, read again, and this time the run reported no locations at all.
        s.pendingContentHash = "newer-hash"
        s.hasUnreadChanges = true
        ingest([event("Louisville", location: nil),
                event("Brooklyn", location: nil)], into: ctx)

        #expect(s.lastPlacedCount == 0)
        // It remembers. A source that once placed can never become "just a venue calendar" by forgetting.
        #expect(s.hasEverPlaced == true)
    }

    // A blank string is not a place. The runbook asks for the page's words verbatim, and a page that renders
    // an empty location field must not read as one that named somewhere.
    @Test func aBlankLocationDoesNotCountAsSayingWhere() throws {
        let ctx = try context()
        let s = source(ctx)

        ingest([event("Blank", location: "   "),
                event("Empty", location: "")], into: ctx)

        #expect(s.lastPlacedCount == 0)
        #expect(s.hasEverPlaced == false)
    }
}
