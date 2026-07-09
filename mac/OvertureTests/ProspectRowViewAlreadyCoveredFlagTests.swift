import Testing
import SwiftUI
import ViewInspector
@testable import Overture

// #611: the "already has its own photographer" fit-risk flag, using the ViewInspector harness
// from #470/#710. Mirrors bookingSuggestionFlag's visual shape (a Menu-wrapped capsule with a
// dismiss action) but is its own view since the underlying signal is a different concept
// (external research about the org, not the drafted email's own text).
@MainActor
@Suite("ProspectRowView already-covered flag (#611)")
struct ProspectRowViewAlreadyCoveredFlagTests {
    private func item(alreadyCoveredNote: String?, alreadyCoveredDismissed: Bool = false) -> QueueItem {
        QueueItem(id: "k", groupName: "French-American Piano Society", discipline: "music", venue: "Weill Recital Hall",
                 performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new,
                 alreadyCoveredNote: alreadyCoveredNote, alreadyCoveredDismissed: alreadyCoveredDismissed)
    }

    @Test func noNoteShowsNoFlagAtAll() throws {
        let view = ProspectRowView(item: item(alreadyCoveredNote: nil), today: "2026-07-09",
                                   onKeep: {}, onDismiss: { _ in })

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(!texts.contains { $0.contains("Photographer in Residence") })
    }

    @Test func aFreshNoteShowsTheFlagWithItsTextAndADismissAction() throws {
        let view = ProspectRowView(item: item(alreadyCoveredNote: "Lists a Photographer in Residence."),
                                   today: "2026-07-09", onKeep: {}, onDismiss: { _ in })

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.contains("Photographer in Residence") })
        _ = try view.inspect().find(button: "Not actually covered")   // throws if absent
    }

    @Test func aDismissedNoteShowsNoFlag() throws {
        let view = ProspectRowView(item: item(alreadyCoveredNote: "Lists a Photographer in Residence.",
                                              alreadyCoveredDismissed: true),
                                   today: "2026-07-09", onKeep: {}, onDismiss: { _ in })

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(!texts.contains { $0.contains("Photographer in Residence") })
    }

    @Test func tappingNotActuallyCoveredFiresTheCallback() throws {
        var dismissed = false
        let view = ProspectRowView(item: item(alreadyCoveredNote: "Lists a Photographer in Residence."),
                                   today: "2026-07-09", onKeep: {}, onDismiss: { _ in },
                                   onDismissAlreadyCoveredFlag: { dismissed = true })

        let button = try view.inspect().find(button: "Not actually covered")
        try button.tap()

        #expect(dismissed == true)
    }
}
