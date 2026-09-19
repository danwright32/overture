import Testing
import Foundation
import SwiftData

// #3324, plan 2.11: the key the scout's `.reKey` arm stores and the `performanceDate` that `apply` then
// assigns must name the SAME night.
//
// Measured 2026-09-17 on a copy of the live store: 19 of 1,260 rows carried a `naturalKey` whose date
// disagreed with `performanceDate`, and the count OSCILLATED. `NaturalKeyVenueMigration.run` repairs them
// at every launch, as a side effect of a pass written for the venue half of the key, and the next scout
// re-creates them. So a "zero drifted rows" assertion over the live store would flip red or green on
// whether a scout has run since the last launch, with nothing changed but the clock (L336, L182). This
// asserts the SIGNATURE at the writer instead, which no launch can quieten (L68).
//
// The writer: the arm stored a key computed from the FEED's opening night, and `apply` then overwrote
// `performanceDate` with the opening left once Dan's dropped nights are subtracted. Two writes, 350 lines
// apart, disagreeing whenever Dan had dropped the opening night.
//
// Every date is pinned and `today` with it (L130).
@MainActor
@Suite("The scout's re-key stores the key of the night it lands on (#3324 2.11)")
struct ScoutReKeyAnchorTests {

    private static let title = "Anchor Test Revue"
    private static let venue = "The Anchor Room"
    private static let nights = ["2026-11-06", "2026-11-13", "2026-11-20"]
    private static func url(_ night: String) -> String { "https://example.test/anchor/\(night)" }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema,
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func storedRun(in ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: Self.title,
                                                             performanceDate: Self.nights.first,
                                                             venue: Self.venue),
                         groupName: Self.title, discipline: "theater",
                         venue: Self.venue, performanceDate: Self.nights.first,
                         sourceListingURL: Self.url(Self.nights[0]), priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "medium", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: Self.nights.last, partOfRelatedRun: true,
                         runSourceURLs: Self.nights.map(Self.url), runNights: Self.nights)
        ctx.insert(p)
        return p
    }

    private func feed() -> [ExtractedEvent] {
        Self.nights.map {
            ExtractedEvent(title: Self.title, presenter: "Anchor Players", venue: Self.venue,
                           performanceDate: $0, sourceUrl: Self.url($0))
        }
    }

    // THE CLAIM. Dan drops the opening night, the row moves to the second, and the feed still lists all
    // three. After the next scout, the stored key and the stored date name one night.
    @Test func aRowWhoseOpeningDanDroppedKeepsAKeyThatNamesItsOwnDate() throws {
        let ctx = ModelContext(try container())
        let p = storedRun(in: ctx)
        let outcome = p.dropNight(Self.nights[0], reason: .dateConflict,
                                  now: Date(timeIntervalSince1970: 1_790_000_000), in: ctx)
        try ctx.save()
        // The precondition, asserted so a failure below cannot come from a drop that never happened (L159).
        #expect(outcome == .moved(to: Self.nights[1], releasing: []))
        #expect(p.naturalKey == p.scoutAnchoredNaturalKey, "the drop itself left the key anchored")

        _ = ScoutService.apply(events: feed(), clients: [], history: [], blocked: .empty,
                               today: "2026-10-01", sourceIds: ["anchor"], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>()).filter { $0.groupName == Self.title }
        #expect(rows.count == 1, "one show, stored \(rows.count) times")
        let row = try #require(rows.first)
        #expect(row.performanceDate == Self.nights[1], "Dan's dropped opening stays dropped")
        #expect(row.naturalKey == row.scoutAnchoredNaturalKey,
                "the scout stored key \(row.naturalKey) on a row whose date is \(row.performanceDate ?? "nil")")
    }

    // The ordinary case is untouched: nothing dropped, the key follows the feed's own opening.
    @Test func anUndroppedRunKeepsTheFeedsOpening() throws {
        let ctx = ModelContext(try container())
        _ = storedRun(in: ctx)
        try ctx.save()

        _ = ScoutService.apply(events: feed(), clients: [], history: [], blocked: .empty,
                               today: "2026-10-01", sourceIds: ["anchor"], into: ctx)
        try ctx.save()

        let row = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first { $0.groupName == Self.title })
        #expect(row.performanceDate == Self.nights[0])
        #expect(row.naturalKey == row.scoutAnchoredNaturalKey)
    }
}
