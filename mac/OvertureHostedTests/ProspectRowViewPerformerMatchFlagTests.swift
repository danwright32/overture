import Testing
import SwiftUI
import ViewInspector
@testable import Overture

// #753: the performer-match flag. The correction is otherwise INVISIBLE: a lead silently goes warm
// and Dan has no way to see why, agree, or reject it. Mirrors alreadyCoveredFlag's Menu-wrapped
// capsule idiom (#611), but carries two actions rather than one, because an unconfirmed match is
// held back from the drafting tone until Dan actively says it is right (#752, his call).
@MainActor
@Suite("ProspectRowView performer-match flag (#753)")
struct ProspectRowViewPerformerMatchFlagTests {
    private let note = "Matched performer 'Marisol Vega' to Downbeat client Marisol Vega."

    private func item(corrected: Bool, reviewed: Bool = false, dismissed: Bool = false) -> QueueItem {
        QueueItem(id: "k", groupName: "Emerging Artists Series", discipline: "music",
                  venue: "Weill Recital Hall", performanceDate: "2026-09-12", sourceListingURL: nil,
                  websiteURL: nil, priorRelationship: corrected ? "booked" : "none", production: "self",
                  profile: "strong", coverage: "likely_uncovered", fitScore: corrected ? 27 : 7,
                  tier: "high", fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                  possibleMatchName: nil, status: .new,
                  relationshipCorrectedByPerformerMatch: corrected,
                  performerMatchNote: corrected ? note : nil,
                  performerMatchDismissed: dismissed,
                  performerMatchReviewed: reviewed)
    }

    private func row(_ item: QueueItem) -> ProspectRowView {
        ProspectRowView(item: item, today: "2026-07-11", onKeep: {}, onDismiss: { _ in })
    }

    private func texts(_ view: ProspectRowView) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    @Test func aProspectWithNoPerformerMatchShowsNoFlag() throws {
        #expect(!(try texts(row(item(corrected: false)))).contains { $0.contains("Marisol Vega") })
    }

    // An unconfirmed match must ASK, not merely inform: until Dan confirms it, the warm tone is held
    // back from any future draft (#752), so the row has to give him a way to say yes.
    @Test func anUnconfirmedMatchShowsTheNoteAndBothActions() throws {
        let view = row(item(corrected: true))

        #expect(try texts(view).contains { $0.contains("Marisol Vega") })
        _ = try view.inspect().find(button: "Looks right")    // throws if absent
        _ = try view.inspect().find(button: "Wrong match")
    }

    // Once confirmed there is nothing left to confirm, but Dan can still change his mind later, so
    // the note and the reject action stay.
    @Test func aConfirmedMatchKeepsTheNoteAndTheRejectAction() throws {
        let view = row(item(corrected: true, reviewed: true))

        #expect(try texts(view).contains { $0.contains("Marisol Vega") })
        _ = try view.inspect().find(button: "Wrong match")
        #expect(throws: (any Error).self) { try view.inspect().find(button: "Looks right") }
    }

    // A rejected match is gone from the row entirely: Phase 4 already reverted the score, so there is
    // nothing left to explain.
    @Test func aDismissedMatchShowsNoFlag() throws {
        #expect(!(try texts(row(item(corrected: true, dismissed: true)))).contains { $0.contains("Marisol Vega") })
    }
}
