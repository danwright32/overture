import Testing
import Foundation
import SwiftData

// #3654 step 4c: the in-app check is a SECOND WRITER of the work tally, and it is counted apart.
//
// WHY THIS IS A TEST AND NOT A COMMENT. The check rebuilds one card per pass through the shipping card
// builder. Without an exclusion, every measured pass would count that card, its send groups, its lint
// runs and its contacts read, and `detailCards == requestedCardKeys.count` could not hold: a pass would
// report one more card than it was asked for, forever, and the pins that make this milestone measurable
// would have to be widened to accommodate the instrument (L375, L63).
//
// The exclusion is STATED AND SCOPED (L324): it covers exactly the work done inside
// `QueueModel.checkOneCardAgainstAFreshBuild`, through one task local, and nothing else.
@MainActor
@Suite("The divergence check's own work is counted apart from the pass's (#3654)")
struct TheOracleIsCountedApartTests {
    private static let corpusSize = 12

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func seed(_ ctx: ModelContext) -> [Prospect] {
        var out: [Prospect] = []
        for n in 0..<Self.corpusSize {
            let p = Prospect(naturalKey: "k\(n)", groupName: "Show \(n)", discipline: "choral",
                             venue: "Room \(n % 3)", performanceDate: "2099-05-01", sourceListingURL: nil,
                             priorRelationship: "none", production: "self", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
            ctx.insert(p)
            if n % 3 == 0 {
                let r = Recipient(id: "c\(n)@example.invalid", email: "c\(n)@example.invalid",
                                  name: "Contact \(n)", provenance: .act)
                r.sendState = .pending
                p.draftBody = LiveContactShape.draftBody
                p.recipients.append(r)
            }
            out.append(p)
        }
        return out
    }

    // THE test. A pass reports exactly one card per show whatever the check does, and the check's own
    // card lands in its own counter.
    @Test func thePassesOwnCountersDoNotMoveWhenTheCheckRuns() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        try ctx.save()

        var scope: QueueModel.Scope?
        let work = QueueRenderPass.WorkTally.measure {
            scope = QueueModel.scope(from: shows, corpus: shows)
        }

        #expect(scope?.cardCheck.ran == true, "the check did not run, so this measured nothing (L98)")
        #expect(work.queueItems == Self.corpusSize, Comment(rawValue:
            "the pass reports \(work.queueItems) cards over \(Self.corpusSize) shows. The check's own "
            + "rebuild is being counted as the pass's work, so every card pin in this repository would "
            + "have to be widened by one to accommodate the instrument (L375)."))
        #expect(work.sendGroupBuilds == Self.corpusSize)
        #expect(work.recipientReaches == Self.corpusSize)
        // And the check's own work is not lost: it is counted, in its own place, so the cost of the
        // instrument is measurable rather than invisible.
        #expect(work.oracleCards == 1)
        #expect(work.oracleSendGroupBuilds == 1)
        #expect(work.oracleRecipientReaches == 1)
    }

    // The exclusion is SCOPED and not a mode left switched on. Anything built outside the check counts as
    // the pass's, which is what stops the task local becoming a way to hide work.
    @Test func workOutsideTheCheckIsStillThePasses() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        try ctx.save()
        let show = try #require(shows.first)

        let work = QueueRenderPass.WorkTally.measure { _ = QueueItem(show) }

        #expect(work.queueItems == 1)
        #expect(work.oracleCards == 0, "an ordinary card build was attributed to the check")
    }

    // THE COST OF THE INSTRUMENT, printed rather than written down, on `WatchdogCostTests`' precedent and
    // for its reason: a number in prose goes stale silently and a number the tool takes every run cannot
    // (L32, L316). #3654 asks for this explicitly, because "one card per pass, so the cost is O(1)" is a
    // comment estimating that work is small enough to run on the hot path, in a milestone whose entire
    // subject is that per-card construction is the cost (L353).
    @Test func theChecksOwnCostIsMeasuredAndPrinted() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        try ctx.save()

        let work = QueueRenderPass.WorkTally.measure { _ = QueueModel.scope(from: shows, corpus: shows) }

        let share = Double(work.oracleCards) / Double(max(work.queueItems, 1))
        print("card-check-cost: \(work.oracleCards) card, \(work.oracleSendGroupBuilds) send group, "
              + "\(work.oracleDraftLintRuns) lint runs and \(work.oracleRecipientReaches) contact reads "
              + "per pass, against \(work.queueItems) cards the pass built "
              + "(\(String(format: "%.1f", share * 100))% of the pass's card work)")
        // ONE card per pass, whatever the corpus is. A check whose cost grew with the store would be the
        // shape this milestone exists to remove, wearing the clothes of the instrument that measures it.
        #expect(work.oracleCards == 1)
    }
}
