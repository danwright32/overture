import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #2015, the half only a rendered view can answer. Dan's rule: "It should show me every email it's going
// to send to and I should be able to add/remove emails as needed."
//
// The contact list, the add control and the per-row remove already existed. What did not was the
// information: a row showed a person's NAME and fell back to the address only when there was no name, and
// nothing said which of several contacts the next Send would actually reach.
@MainActor
@Suite("Every address is on screen (#2015)")
struct EveryAddressOnScreenTests {
    private func allTexts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    private func contact(_ email: String, _ name: String?, next: Bool = false,
                         held: Bool = false) -> RecipientSnapshot {
        var r = RecipientSnapshot(id: email, name: name, email: email, role: nil,
                                  provenance: .act, sendState: .pending, replied: false,
                                  lastReplyText: nil, resolution: nil, bounced: false,
                                  outcomeSource: nil)
        r.isHeldFromSending = held
        return r
    }

    private func item(_ contacts: [RecipientSnapshot], next: String? = nil) -> QueueItem {
        var item = QueueItem(
            id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
            performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
            priorRelationship: "none", production: "self", profile: "strong",
            coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
            matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .approved)
        item.contacts = contacts
        item.nextRecipientIds = next.map { [$0] } ?? []
        item.draftSubject = "Photographing Aurora Strings"
        item.draftBody = "I photograph performing arts in New York."
        return item
    }

    private func view(_ item: QueueItem) -> some View {
        DraftReviewView(item: item, onUnapprove: {}, onSkip: {}, onSaveDraft: { _, _ in })
    }

    // The address itself, on the row, even though the contact has a name to show instead.
    @Test func theaddressIsShownEvenWhenTheContactHasAName() throws {
        let rendered = view(item([contact("sarah@company.example", "Sarah Chen")]))
        let texts = try allTexts(rendered)

        #expect(texts.contains("Sarah Chen"))
        #expect(texts.contains("sarah@company.example"), "the address must be readable, not just the name")
    }

    // Dan's own failure, on screen: two contacts, and the card says which one is actually about to be
    // emailed rather than leaving him to guess from an order he cannot see.
    @Test func thecardSaysWhichContactTheNextSendGoesTo() throws {
        let rendered = view(item([contact("info@thevenue.example", nil),
                                  contact("sarah@company.example", "Sarah Chen")],
                                 next: "info@thevenue.example"))

        #expect(try allTexts(rendered).contains("Sending to this one"))
    }

    // And it says it exactly once, or it tells him two addresses are next.
    @Test func onlyoneContactIsMarkedAsNext() throws {
        let rendered = view(item([contact("info@thevenue.example", nil),
                                  contact("sarah@company.example", "Sarah Chen")],
                                 next: "info@thevenue.example"))

        #expect(try allTexts(rendered).filter { $0 == "Sending to this one" }.count == 1)
    }

    // A contact a guard is holding is on the show but is not going to be emailed, and the list says so
    // rather than letting it read as one more address that will receive the pitch.
    @Test func aheldContactIsMarkedAsNotSending() throws {
        let rendered = view(item([contact("press@thevenue.example", "Press Office", held: true)]))

        #expect(try allTexts(rendered).contains("Held, not sending"))
    }

    // Neither marker appears on an ordinary contact, or they mean nothing.
    @Test func anordinaryContactCarriesNeitherMarker() throws {
        let rendered = view(item([contact("sarah@company.example", "Sarah Chen")]))
        let texts = try allTexts(rendered)

        #expect(!texts.contains("Held, not sending"))
        #expect(!texts.contains("Sending to this one"))
    }

    // The add control is on the same list, so "add/remove emails as needed" is reachable from where he
    // reads the addresses rather than somewhere else.
    @Test func theaddContactControlSitsWithTheList() throws {
        let rendered = view(item([contact("sarah@company.example", "Sarah Chen")]))

        #expect(try allTexts(rendered).contains("Add contact"))
    }
}
