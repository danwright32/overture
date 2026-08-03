import Testing
import Foundation
import SwiftData

// #1005 / #1001: the placement detector (#986) was wired into the AGENT path's recorder only, so the
// native (Carnegie) path never set lastPlacedCount / hadPlacedBeforeLastRun and its placement count stayed
// zero no matter what its feed said. Consolidating the shared bookkeeping into ONE function that both paths
// call is the fix: the placement count then records for both from one place, not a third copy. (#1029 later
// removed the Dan-facing line the count fed; the recorded count these tests pin stays, for #970's drift check.)
//
// These drive the REAL native scout (ScoutService.runScout over an algolia Carnegie row), because the count
// and the WIRE that carries it to the row are two separate claims. SourcePlacement.placedCount can be perfect
// while nothing on the native path ever feeds it, and every existing placement test would still pass. That
// exact class of cut has gone unnoticed here before (#986/#887).
@MainActor
@Suite("The native ingest path records placement and health too (#1005/#1001)")
struct NativePathPlacementTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "NativePathPlacementTests-\(UUID().uuidString)")!
    }

    // Carnegie's own row: the native path only records onto a source that exists, and this is the one row
    // the native sweep runs for.
    @discardableResult
    private func carnegie(_ ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: WatchedSource.carnegieId, orgName: "Carnegie Hall",
                              listingsURL: "https://www.carnegiehall.org/Calendar", kind: .algolia)
        ctx.insert(s)
        return s
    }

    private func event(_ title: String, venue: String?, location: String?) -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: title, venue: venue,
                       performanceDate: "2099-09-19",
                       sourceUrl: "https://www.carnegiehall.org/Calendar/2099/09/19/\(title)",
                       location: location)
    }

    private func runNativeScout(_ events: [ExtractedEvent], into ctx: ModelContext) async throws {
        _ = try await ScoutService.runScout(
            into: ctx,
            extractor: StubSourceExtractor(listing: ExtractedListing(events: events,
                                                                     verdict: .upcomingListings)),
            now: now,
            defaults: defaults())
    }

    // THE #1005 fix, through the native door. A run whose kept shows named WHERE they are records that on
    // the source row, exactly as the agent path already does. Before the consolidation this stayed 0.
    @Test func aNativeRunThatPlacesRecordsItOnTheSourceRow() async throws {
        let ctx = try context()
        let s = carnegie(ctx)

        try await runNativeScout([event("Louisville", venue: "Zankel Hall", location: "Louisville, KY"),
                                  event("Brooklyn", venue: "Weill Recital Hall", location: "Brooklyn, NY")],
                                 into: ctx)

        #expect(s.lastPlacedCount == 2)
        #expect(s.hadPlacedBeforeLastRun == false)   // its FIRST placing run
        #expect(s.hasEverPlaced == true)
    }

    // A blank location is not a place, on this path as on the other: the guard keeps the show (it has a
    // venue) but it does not count as saying where.
    @Test func aNativeRunWithNoLocationsPlacesNothing() async throws {
        let ctx = try context()
        let s = carnegie(ctx)

        try await runNativeScout([event("Quiet", venue: "Zankel Hall", location: nil),
                                  event("Blank", venue: "Weill Recital Hall", location: "  ")],
                                 into: ctx)

        #expect(s.lastPlacedCount == 0)
        #expect(s.hasEverPlaced == false)
    }

    // The ordering invariant (#986): the pre-run answer is captured BEFORE this run's count overwrites it.
    // A source that placed and now places nothing has DRIFTED, and it must remember it once placed, so the
    // geographic gate being off for it is loud rather than silent.
    @Test func aNativeSourceThatStopsPlacingRemembersItDid() async throws {
        let ctx = try context()
        let s = carnegie(ctx)

        try await runNativeScout([event("Louisville", venue: "Zankel Hall", location: "Louisville, KY")],
                                 into: ctx)
        #expect(s.hasEverPlaced == true)

        try await runNativeScout([event("Louisville", venue: "Zankel Hall", location: nil)], into: ctx)

        #expect(s.lastPlacedCount == 0)
        #expect(s.hadPlacedBeforeLastRun == true)   // it placed on the prior run
        #expect(s.hasEverPlaced == true)            // and never forgets it
    }

    // The #891 readable/unreadable counts and the #150/#152 health fold still land on the native path, and
    // on the SAME successful branch as the run: two shows are kept (readable), one has no venue and is
    // dropped by the guard, and the feed folds to a fresh baseline of the kept size.
    //
    // #1472: that drop is recorded as a STRUCTURAL GAP, not as an unreadable page. Carnegie's Algolia feed
    // is parsed row by row with no per-event detail page to fetch, so a blank venue is what the publisher
    // wrote, and counting it as a page Overture failed to open is what cost National Opera Center its
    // gone-marking permanently. Both counts are asserted, so a future change cannot quietly move a drop from
    // one column to the other.
    @Test func aNativeRunRecordsReadableUnreadableAndHealth() async throws {
        let ctx = try context()
        let s = carnegie(ctx)

        try await runNativeScout([event("Kept", venue: "Zankel Hall", location: "Louisville, KY"),
                                  event("AlsoKept", venue: "Weill Recital Hall", location: nil),
                                  event("Dropped", venue: nil, location: nil)],
                                 into: ctx)

        #expect(s.lastReadableCount == 2)
        #expect(s.lastUnreadableCount == 0)
        #expect(s.lastStructuralGapCount == 1)
        #expect(s.baselineFeedCount == 2)
        #expect(s.successfulCheckCount == 1)
        #expect(s.health == .ok)
    }
}
