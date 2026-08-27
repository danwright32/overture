import Testing
import Foundation
import SwiftData

// #1820. `LocalHistory.schedulingDismissals` carried a comment saying those reasons keep an org as a
// "hot future lead (1.2 / #70)". That stopped being true at #1362, which weighted a past decline
// NEUTRAL on the explicit grounds that it is usually just an old date conflict. The two comments sat
// nine lines apart and contradicted each other, and the stale one is the one a reader meets first.
//
// It is not an ordinary stale comment because of where it sits: it is what a person reads while deciding
// which dismiss reason to CHOOSE. On 2026-07-30 it produced a wrong answer to Dan about clearing the
// other shows on a committed night (#1819), telling him "Date conflict" would keep those orgs hot.
//
// The comment is now what the code does. These tests pin the code, so the comment cannot go stale again
// without something failing: a comment is not checkable, and the fact behind it is (L32).
@MainActor
@Suite("A scheduling miss is neutral, not a boost (#1820)")
struct ASchedulingMissIsNeutralTests {

    // The fact the old comment got wrong. Asserted against the COLD lead's own score rather than
    // against the literal 0, because the claim being protected is "a scheduling miss is treated like
    // never having met them", and that stays the claim if the whole scale is ever renumbered.
    @Test func aPastDeclineScoresExactlyAsAColdLead() {
        #expect(Ranker.priorPoints(.declinedByYou) == 0)
        #expect(Ranker.priorPoints(.declinedByYou) == Ranker.priorPoints(.none))
    }

    // And it is emphatically not a boost, which is what the comment claimed for a year.
    @Test func aPastDeclineIsNotWarmAndNotBooked() {
        #expect(Ranker.priorPoints(.declinedByYou) < Ranker.priorPoints(.warm))
        #expect(Ranker.priorPoints(.declinedByYou) < Ranker.priorPoints(.booked))
    }

    // The other half of #1820's point, and the reason the set exists at all: a scheduling miss must not
    // be recorded as anything that reads as a judgement about the org. Every outcome in the set records
    // the same thing, so no one of them is quietly harsher than the others.
    @Test func everySchedulingMissRecordsTheSameNeutralFact() throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))

        var recorded: [ShowOutcome: String] = [:]
        for outcome in [ShowOutcome.dateConflict, .hadPaidWork, .pitchingOtherShows] {
            let p = Prospect(naturalKey: "k-\(outcome.rawValue)", groupName: "Aurora Strings",
                             discipline: "music", venue: "V", performanceDate: "2026-09-01",
                             sourceListingURL: nil, priorRelationship: "none",
                             production: "self", profile: "neutral", coverage: "unknown",
                             fitScore: 3, tier: "longshot", fitReason: "r", matchedClientName: nil,
                             possibleMatchSource: nil, possibleMatchName: nil, status: .dismissed)
            p.markDismissed(reason: outcome)
            ctx.insert(p)
            let record = LocalHistory.records(from: [p]).first
            recorded[outcome] = record?.status
        }

        #expect(recorded.count == 3, "one of the scheduling misses produced no history record at all")
        #expect(Set(recorded.values.compactMap { $0 }).count == 1,
                "the scheduling misses recorded different statuses: \(recorded)")
        #expect(recorded[.dateConflict] == "declined")
    }

    // The stale number itself. A weighting stated in a comment and applied nowhere is the exact defect,
    // so the guard is that no comment in the domain claims one: `1.2` appeared in that comment and in no
    // line of code anywhere.
    @Test func noCommentClaimsAMultiplierTheRankerDoesNotApply() throws {
        let source = SourceGuardHelper.source("Overture/Domain/LocalHistory.swift")
        #expect(!source.isEmpty)
        let claim = "these stay hot future leads"
        #expect(!source.contains(claim),
                "LocalHistory still claims a scheduling miss keeps an org hot; Ranker.priorPoints gives it 0")
    }
}
