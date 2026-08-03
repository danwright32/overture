import Testing
import Foundation
import SwiftData

// #1128: a Dan-chosen "Too soon" dismiss reason for a show he WOULD want to shoot but only found out
// about too late to pitch. It must be its own case (a missed opportunity, never folded into "Not a fit"),
// offered wherever the other Dan-choosable reasons are, and distinct from the self-set "Went by".
@MainActor
@Suite("Too soon dismiss reason (#1128)")
struct TooSoonDismissReasonTests {

    // (a) Dan can pick it himself: it rides in the same list the dismiss menu renders from.
    @Test func tooSoonIsOfferedToDan() {
        #expect(DismissReason.danCanChoose.contains(.tooSoon))
    }

    // (b) It is a genuinely distinct case, never the same value as "Not a fit" or the self-set "Went by".
    @Test func tooSoonIsDistinctFromNotAFitAndWentBy() {
        #expect(DismissReason.tooSoon != .notInterested)
        #expect(DismissReason.tooSoon != .wentBy)
        #expect(DismissReason.tooSoon != .dontWantToShoot)
        // A unique raw value so the score-vs-outcome capture can tell it apart from every other reason.
        let raws = DismissReason.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
        #expect(DismissReason.tooSoon.rawValue == "too_soon")
    }

    // Its own wording, so Dan reads a reason distinct from the others in the menu.
    @Test func tooSoonHasItsOwnLabel() {
        #expect(DismissReason.tooSoon.label == "Too soon")
        let labels = DismissReason.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
    }

    // "Went by" stays Overture's own, never offered as a choice (the #864 rule the new case must not break).
    @Test func wentByStillNotOffered() {
        #expect(!DismissReason.danCanChoose.contains(.wentBy))
    }

    // A "too soon" dismissal is a missed opportunity, not a judgement about the show, so like "Not a fit"
    // it must teach LocalHistory nothing: it must never down-rank the org or the show (feeds #4's capture).
    @Test func tooSoonDismissalRecordsNothingInHistory() throws {
        let container = try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = ModelContext(container)
        let p = Prospect(naturalKey: "Late Find", groupName: "Late Find", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-20", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .dismissed, dismissReason: .tooSoon)
        ctx.insert(p)
        #expect(LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>())).isEmpty)
    }
}
