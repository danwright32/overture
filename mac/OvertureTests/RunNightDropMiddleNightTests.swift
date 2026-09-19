import Testing
import Foundation
import SwiftData

// #3325, plan 3.7: dropping a night that is NOT the run's opening, specified as writes.
//
// | | opening-night drop | any other night |
// | forward walk | runs | does not run |
// | released | as today | empty |
// | runNights | night removed | night removed |
// | performanceDate | rewritten | untouched |
// | runEndDate | kept.max() | kept.max(), so dropping the closing night moves it |
// | naturalKey | rewritten | untouched |
@MainActor
@Suite("Dropping a middle or closing night of a run (#3325 3.7)")
struct RunNightDropMiddleNightTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static let nights = ["2026-11-06", "2026-11-13", "2026-11-20"]

    private func run(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: "Middle Revue",
                                                             performanceDate: Self.nights[0], venue: "Room"),
                         groupName: "Middle Revue", discipline: "theater", venue: "Room",
                         performanceDate: Self.nights[0], sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "medium", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.runEndDate = Self.nights.last
        p.runNights = Self.nights
        ctx.insert(p)
        return p
    }

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: AppSchema.schema,
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @Test func aMiddleNightLeavesTheOpeningTheKeyAndTheSpanAlone() throws {
        let ctx = try context()
        let p = run(ctx)
        let key = p.naturalKey
        // A card holding the LAST night: the walk would release onto it if it ran, which it must not.
        let lookups = Counter()
        let outcome = p.dropNight("2026-11-13", reason: .tooSoon, now: now,
                                  lookup: { _ in lookups.count += 1; return nil })
        #expect(outcome == .moved(to: "2026-11-06", releasing: []))
        #expect(lookups.count == 0, "the forward walk ran for a night that is not the opening")
        #expect(p.runNights == ["2026-11-06", "2026-11-20"])
        #expect(p.performanceDate == "2026-11-06")
        #expect(p.runEndDate == "2026-11-20")
        #expect(p.naturalKey == key)
        #expect(p.nightState("2026-11-13") == .dropped)
    }

    @Test func theClosingNightMovesTheEndOfTheSpan() throws {
        let ctx = try context()
        let p = run(ctx)
        _ = p.dropNight("2026-11-20", reason: .tooSoon, now: now, lookup: { _ in nil })
        #expect(p.runEndDate == "2026-11-13")
        #expect(p.performanceDate == "2026-11-06")
    }

    // The opening-night branch is unchanged: it walks, moves the date, and moves the key.
    @Test func theOpeningNightStillMovesTheCard() throws {
        let ctx = try context()
        let p = run(ctx)
        let outcome = p.dropNight("2026-11-06", reason: .tooSoon, now: now, lookup: { _ in nil })
        #expect(outcome == .moved(to: "2026-11-13", releasing: []))
        #expect(p.performanceDate == "2026-11-13")
        #expect(p.naturalKey == p.scoutAnchoredNaturalKey)
    }

    private final class Counter { var count = 0 }
}
