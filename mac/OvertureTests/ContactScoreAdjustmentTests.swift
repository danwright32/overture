import Testing
import Foundation
import SwiftData
@testable import Overture

// #1648 Phases D and E: the contact answer moves the STORED score, once, and leaves a record of what
// the score was before it did.
@MainActor
@Suite("Contact answer moves the stored score")
struct ContactScoreAdjustmentTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // music 1 + self 2 + strong 2 + likely_uncovered 2 = 7, no relationship.
    @discardableResult
    private func show(_ ctx: ModelContext, key: String = "k") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    private let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aFoundEmailRaisesTheStoredScoreAndRecordsWhatItWas() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.reachabilityProbedAt = checkedAt
        p.reachabilityResultRaw = Reachability.ProbeResult.emailFound.rawValue

        ContactScoreAdjustment.settle(p, now: checkedAt)

        #expect(p.fitScore == 9)                          // 7 + 2
        #expect(p.fitScoreBeforeContactCheck == 7)        // the retuning baseline
        #expect(p.contactRouteAtScore == "email_found")   // and the answer that moved it
    }

    // The adjustment is a re-score from the row, never arithmetic on the stored number, so settling the
    // same answer repeatedly cannot drift. This is the guard that lets it be called from more than one
    // place (the probe settle, and the reconcile pass) without them fighting.
    @Test func settlingTheSameAnswerTwiceChangesNothingTheSecondTime() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.reachabilityProbedAt = checkedAt
        p.reachabilityResultRaw = Reachability.ProbeResult.emailFound.rawValue

        #expect(ContactScoreAdjustment.settle(p, now: checkedAt) == true)
        #expect(ContactScoreAdjustment.settle(p, now: checkedAt) == false)
        #expect(p.fitScore == 9)                    // NOT 11
        #expect(p.fitScoreBeforeContactCheck == 7)  // and the baseline was not overwritten with 9
    }

    // 536 of 559 untriaged shows are in this state. Nothing may touch them.
    @Test func aShowNobodyCheckedIsLeftCompletelyAlone() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)

        #expect(ContactScoreAdjustment.settle(p, now: checkedAt) == false)
        #expect(p.fitScore == 7)
        #expect(p.fitScoreBeforeContactCheck == nil)
        #expect(p.contactRouteAtScore == nil)
    }

    @Test func aDeadEndDropsTheStoredScoreAndTheTierWithIt() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.reachabilityProbedAt = checkedAt
        p.reachabilityResultRaw = Reachability.ProbeResult.noEmailFound.rawValue

        ContactScoreAdjustment.settle(p, now: checkedAt)

        #expect(p.fitScore == 2)          // 7 - 5
        #expect(p.tier == "longshot")     // and it really leaves the high-fit view
        #expect(p.fitScoreBeforeContactCheck == 7)
    }

    // Dan's decision, 2026-07-28: an answer past its 90 day expiry lifts its own adjustment, at the same
    // moment the badge reverts to "worth re-checking", so the card and the score never disagree about
    // whether an answer is current. It RECOMPUTES rather than restoring the stored baseline, which would
    // also silently undo any unrelated correction made in between.
    @Test func anAnswerThatHasAgedOutGivesTheShowItsScoreBack() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.reachabilityProbedAt = checkedAt
        p.reachabilityResultRaw = Reachability.ProbeResult.noEmailFound.rawValue
        ContactScoreAdjustment.settle(p, now: checkedAt)
        #expect(p.fitScore == 2)

        // 91 days later, past Reachability.probeFreshness.
        let later = checkedAt.addingTimeInterval(91 * 24 * 60 * 60)
        #expect(ContactScoreAdjustment.settle(p, now: later) == true)

        #expect(p.fitScore == 7)                       // the penalty has lifted
        #expect(p.tier == "high")
        #expect(p.contactRouteAtScore == "unchecked")  // and the row says why
    }

    // The recompute is the point: a stale answer must not rewind an unrelated correction made since.
    @Test func liftingAStaleAnswerKeepsACorrectionMadeInBetween() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.reachabilityProbedAt = checkedAt
        p.reachabilityResultRaw = Reachability.ProbeResult.noEmailFound.rawValue
        ContactScoreAdjustment.settle(p, now: checkedAt)

        // Dan corrects the genre from music to dance (+2) while the penalty stands.
        ClassificationOverride.correct(p, discipline: .dance, now: checkedAt)
        #expect(p.fitScore == 4)   // dance 3 + self 2 + strong 2 + uncovered 2 = 9, less 5

        let later = checkedAt.addingTimeInterval(91 * 24 * 60 * 60)
        ContactScoreAdjustment.settle(p, now: later)

        // 9, not the 7 it scored as music. A blind restore of the baseline would have given 7.
        #expect(p.fitScore == 9)
        #expect(p.discipline == "dance")
    }
}
