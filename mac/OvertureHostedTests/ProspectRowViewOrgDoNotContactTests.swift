import Testing
import SwiftUI
import ViewInspector
@testable import Overture

// #769: do-not-contact is the most consequential state a row can carry, and the one that is worst to
// hold invisibly. If Dan can't see it, he can't trust it, and he can't undo a mis-click.
@MainActor
@Suite("ProspectRowView org do-not-contact flag (#769)")
struct ProspectRowViewOrgDoNotContactTests {
    private func item(orgDoNotContact: Bool) -> QueueItem {
        QueueItem(id: "k", groupName: "Refused Chorale", discipline: "music",
                  venue: "Weill Recital Hall", performanceDate: "2026-09-12", sourceListingURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                  coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                  matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                  status: .new, orgDoNotContact: orgDoNotContact)
    }

    private func row(_ item: QueueItem) -> ProspectRowView {
        ProspectRowView(item: item, today: "2026-07-11", onKeep: {}, onDismiss: { _ in })
    }

    private func texts(_ view: ProspectRowView) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    @Test func anOrdinaryRowShowsNoDoNotContactTag() throws {
        #expect(!(try texts(row(item(orgDoNotContact: false)))).contains { $0.contains("Do not contact") })
    }

    // Stated plainly, not tucked away: this is the state that stops Dan emailing someone who asked him
    // to stop, so it has to be legible at a glance.
    @Test func aRefusedOrgShowsTheTagPlainly() throws {
        #expect(try texts(row(item(orgDoNotContact: true))).contains { $0.contains("Do not contact") })
    }

    // Reversible. A mis-click must never cost him an org forever.
    @Test func theTagOffersAWayBack() throws {
        _ = try row(item(orgDoNotContact: true)).inspect().find(button: "Allow contact again")
    }
}
