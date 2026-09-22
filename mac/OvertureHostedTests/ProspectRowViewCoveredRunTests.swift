import Testing
import SwiftUI
import ViewInspector
@testable import Overture

// #2998: the card that says every other night of this run is already on its own card, and the one
// press that retires it.
//
// Here as well as in `ARedundantRunCanBeRetiredTests`, which asserts the SENTENCE and the rule behind
// it, because a sentence a view never renders says nothing and a control nobody draws cannot be
// pressed (#1547, #1995). This drives the real `ProspectRowView`, and it is the only place the press
// itself is exercised end to end.
@MainActor
@Suite("A card offers to retire a run every other card covers (#2998)")
struct ProspectRowViewCoveredRunTests {
    private func item(covered: Bool) -> QueueItem {
        var item = QueueItem(id: "k", groupName: "Steven Maglio & His Big Band Orchestra",
                             discipline: "music", venue: "The Cutting Room",
                             performanceDate: "2026-09-13",
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 7,
                             tier: "high", fitReason: "r", matchedClientName: nil,
                             possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        item.everyOtherNightIsOnItsOwnCard = covered
        return item
    }

    private func row(_ item: QueueItem, onDismiss: @escaping (ShowOutcome) -> Void = { _ in })
    -> ProspectRowView {
        ProspectRowView(item: item, today: "2026-09-19", onKeep: {}, onDismiss: onDismiss)
    }

    private func texts(_ view: ProspectRowView) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // The healthy day, which is all but one card in the store: nothing is drawn at all.
    @Test func anOrdinaryCardOffersNothing() throws {
        let found = try texts(row(item(covered: false)))
        #expect(!found.contains { $0.contains("own card") })
        #expect(!found.contains { $0 == CoveredRunCopy.retire })
    }

    @Test func acoveredRunSaysSoAndOffersTheRetire() throws {
        let found = try texts(row(item(covered: true)))
        #expect(found.contains { $0 == "Every night of this run is already on its own card." })
        #expect(found.contains { $0 == CoveredRunCopy.retire })
    }

    // THE PRESS, which is the half no sentence test can reach. It goes through the same `onDismiss`
    // the dismiss menu uses, with the reason the store already has for it, so the row leaves the queue
    // and comes back from the Archive rather than being deleted (Dan's call, 2026-09-22).
    @Test func thepressDismissesTheRunAsADuplicate() throws {
        var reasons: [ShowOutcome] = []
        let view = row(item(covered: true), onDismiss: { reasons.append($0) })
        try view.inspect().find(button: CoveredRunCopy.retire).tap()
        #expect(reasons == [.duplicate],
                "the retire pressed something other than the duplicate dismissal: \(reasons)")
    }

    // Both themes, because a token that clears the contrast bar on one surface can be invisible on the
    // other, and the suite is the only place this is looked at in dark (L606, L569).
    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func thenoteAndItsControlRenderInBothThemes(_ scheme: ColorScheme) throws {
        let view = row(item(covered: true)).environment(\.colorScheme, scheme)
        let found = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(found.contains { $0 == "Every night of this run is already on its own card." })
        #expect(found.contains { $0 == CoveredRunCopy.retire })
    }
}
