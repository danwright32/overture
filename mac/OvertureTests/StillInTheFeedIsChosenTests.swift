import Testing
import Foundation
import SwiftData

// #3780: `NaturalKeyVenueMigration.stillInTheFeed` was `members.first { $0.missedScoutCount == 0 }`,
// so where several members are live, WHICH row counts as "the one the feed is publishing" depended on
// the order its caller happened to hand them in.
//
// That decides what `carryTheFeedIdentity` copies onto the survivor before the losers are deleted, so
// an arbitrary pick is an arbitrary `sourceListingURL`, `runSourceURLs` and `sourceIds` on the row
// that survives, and for the callers that adopt it, an arbitrary natural key.
//
// The ladder immediately beside it was given a deterministic tie-break for exactly this reason:
// `ScoutService.matchByConcertIdentity` says in its own comment "Deterministic, never `first` on an
// unordered fetch", because an arbitrary pick landed Dan's dismissal on a different row each sweep.
//
// THE PREMISE, RE-CHECKED, because the function's own comment said this could not happen. It claimed
// "`members` is ordered oldest first by every caller" (landed with #3582 on 2026-09-06). Measured
// 2026-09-19 against the two callers:
//
//   `SameNightTitleVariantMerge` DOES sort, by `ingestedAt` ascending, so its order is fixed except
//   where two rows share an `ingestedAt`: Swift's sort is not stable, so a tie there is arbitrary.
//
//   `NaturalKeyVenueMigration`'s own caller does NOT. It builds `members` with
//   `anchors.flatMap { byAnchor[$0] ?? [] }` inside `for (_, anchors) in byDisplay`, and `byDisplay`
//   is a Dictionary, whose iteration order Swift randomises per process. So that caller hands over a
//   genuinely unordered list and the comment is false for it.
//
// The shuffle test below is the one that can see this. A fixture that builds its rows in one order
// and asserts one answer passes whatever the rule does with the others (L159).
@MainActor
@Suite("Which live row counts as the one the feed is publishing (#3780)")
struct StillInTheFeedIsChosenTests {

    private func memoryContext() throws -> ModelContext {
        let schema = Schema([Prospect.self, Recipient.self])
        return ModelContext(try ModelContainer(for: schema,
                            configurations: [ModelConfiguration(schema: schema,
                                                                isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func row(_ ctx: ModelContext, key: String, ingested: Double, missed: Int = 0) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "A Show", discipline: "theater",
                         venue: "A Room", performanceDate: "2026-10-02", sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "unknown",
                         coverage: "unknown", fitScore: 3, tier: "medium", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.ingestedAt = Date(timeIntervalSince1970: ingested)
        p.missedScoutCount = missed
        ctx.insert(p)
        return p
    }

    // A row the feed has stopped listing is never the one the feed is publishing, however fresh its
    // stamp. This is the arm that must keep working, and it is what the function was already right
    // about.
    @Test func aRowWithMissesIsNeverChosen() throws {
        let ctx = try memoryContext()
        let stale = row(ctx, key: "stale", ingested: 9_000, missed: 4)
        let live = row(ctx, key: "live", ingested: 1_000)
        #expect(NaturalKeyVenueMigration.stillInTheFeed([stale, live])?.naturalKey == "live")
    }

    @Test func nothingIsChosenWhenNoMemberIsLive() throws {
        let ctx = try memoryContext()
        let a = row(ctx, key: "a", ingested: 1_000, missed: 2)
        let b = row(ctx, key: "b", ingested: 2_000, missed: 9)
        #expect(NaturalKeyVenueMigration.stillInTheFeed([a, b]) == nil)
    }

    // Among rows the feed still lists, the one it touched most recently. `ingestedAt` is rewritten on
    // every re-scout, so it means LAST SEEN, which is the question being asked. The sibling rule at
    // `NaturalKeyVenueMigration`'s `freshest` picks the same way for the same reason.
    @Test func theFreshestLiveRowIsChosen() throws {
        let ctx = try memoryContext()
        let older = row(ctx, key: "older", ingested: 1_000)
        let fresher = row(ctx, key: "fresher", ingested: 5_000)
        #expect(NaturalKeyVenueMigration.stillInTheFeed([older, fresher])?.naturalKey == "fresher")
        #expect(NaturalKeyVenueMigration.stillInTheFeed([fresher, older])?.naturalKey == "fresher")
    }

    // THE ONE THAT CATCHES #3780. Every order of the same members must give the same answer, or the
    // row whose feed identity is carried onto the survivor is decided by a Dictionary's iteration
    // order, which Swift randomises per process.
    @Test func theAnswerDoesNotDependOnTheOrderTheMembersArriveIn() throws {
        let ctx = try memoryContext()
        let members = [
            row(ctx, key: "alpha", ingested: 4_000),
            row(ctx, key: "bravo", ingested: 4_000),
            row(ctx, key: "charlie", ingested: 4_000),
            row(ctx, key: "delta", ingested: 1_000),
        ]
        let answers = Set((0..<40).compactMap { _ in
            NaturalKeyVenueMigration.stillInTheFeed(members.shuffled())?.naturalKey
        })
        #expect(answers.count == 1,
                Comment(rawValue: "the pick changes with the order the members arrive in: \(answers)"))
    }

    // And the tie is broken by something TOTAL, so the answer is not merely stable within one run but
    // the same on every machine and every launch. The natural key is unique by construction, which is
    // what makes it a total order rather than another coin toss.
    @Test func aTieOnFreshnessIsBrokenByTheNaturalKey() throws {
        let ctx = try memoryContext()
        let members = [
            row(ctx, key: "charlie", ingested: 4_000),
            row(ctx, key: "alpha", ingested: 4_000),
            row(ctx, key: "bravo", ingested: 4_000),
        ]
        #expect(NaturalKeyVenueMigration.stillInTheFeed(members)?.naturalKey == "alpha")
    }
}
