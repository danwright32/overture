import Testing
import SwiftUI
import ViewInspector
@testable import Overture

// #3341. The triage card told Dan to add a contact by hand and gave him nowhere to put one: the field
// lives inside DraftReviewView, which ProspectRowView only draws under `if item.hasDraft`, so acting on
// the card's own advice cost a Prep run on a show the card had just called a long shot.
//
// Rendered through ViewInspector rather than asserted on the predicate alone, because the predicate being
// right is a separate claim from the field actually appearing on the card, and logic in a SwiftUI view is
// untestable unless exercised (#863).
@MainActor
@Suite("The triage card takes a contact by hand (#3341)")
struct TriageCardContactFieldTests {
    private func item(_ reason: Reachability.EmptyReason?) -> QueueItem {
        var i = QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music",
                          venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                          sourceListingURL: nil, priorRelationship: "none", production: "self",
                          profile: "strong", coverage: "likely_uncovered", fitScore: 6, tier: "mid",
                          fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                          possibleMatchName: nil, status: .new)
        // Against the LIVE clock, for #3169's reason: the row asks for the badge with no `now` and reads
        // the wall clock at render time, so a pinned instant stops meaning "probed recently" the moment
        // real time walks past the freshness window.
        i.reachabilityProbedAt = LiveClockProbe.fresh
        i.reachabilityResult = .noEmailFound
        i.reachabilityEmptyReason = reason
        return i
    }

    private func placeholders(_ item: QueueItem) throws -> [String] {
        let view = ProspectRowView(item: item, today: "2026-07-09", onKeep: {}, onDismiss: { _ in })
        return try view.inspect().findAll(ViewType.TextField.self).compactMap {
            try? $0.labelView().text().string()
        }
    }

    // The card Dan reported: "Only names, no way to reach them", whose help says a search by name often
    // turns up an address the check missed. He does that search; this is where the answer goes.
    @Test func aCardThatAsksForAContactOffersSomewhereToPutOne() throws {
        #expect(try placeholders(item(.namedButNoRoute)).contains("Email or link"),
                Comment(rawValue: "the card still tells him to add a contact by hand and gives him "
                    + "nowhere to put one, which is the defect this closes"))
    }

    // And the mirror, which is what keeps it off the rows that did not ask. `routeNamedButNotSupplied`
    // says in its own words that another check is worth more here than a search by hand, so a field
    // inviting one would contradict the line directly above it (L109).
    @Test func aCardThatAsksForAnotherCheckOffersNoField() throws {
        #expect(!(try placeholders(item(.routeNamedButNotSupplied))
            .contains("Email or link")),
                "a field inviting a search sits under a sentence saying a search is worth less here")
    }
}
