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
            performanceDate: "2026-09-12", sourceListingURL: nil,
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
        DraftReviewView(item: item, onUnapprove: {}, onSaveDraft: { _, _ in })
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

    // #2549. Dan, walking the review queue on 2026-08-11, pointing at two places on one card: "there are
    // 2 places that say the email, that seems redundant."
    //
    // The contact line above the draft echoed the address small and grey on the right, and the Contacts
    // block below the action row printed the same address again. Both were locally defensible: the echo
    // justified itself against the LEFT of its own line, and the Contacts block did not exist in the same
    // breath. Two correct local decisions, one duplicated line on screen (#843's shape).
    //
    // Counted rather than pattern-matched on the source, because "how many times does this card say it"
    // is the actual question, and it is the one thing only a rendered view can answer.
    @Test func thecardSaysEachAddressExactlyOnce() throws {
        let rendered = view(item([contact("sarah@company.example", "Sarah Chen")]))
        let texts = try allTexts(rendered)

        #expect(texts.filter { $0 == "sarah@company.example" }.count == 1,
                "the address appears \(texts.filter { $0 == "sarah@company.example" }.count) times: \(texts)")
        // The line that stays is the Contacts block's, which is the one that scales past one recipient
        // and carries the send state and the strike control beside it.
        #expect(texts.contains("Sarah Chen"), "the contact's name still identifies who the draft is for")
    }

    // The address must not be lost on the way: a contact with no name has nothing else identifying it, so
    // it still has to be readable on the card.
    @Test func anaddressWithNoNameIsStillReadable() throws {
        let rendered = view(item([contact("info@thevenue.example", nil)]))

        #expect(try allTexts(rendered).contains("info@thevenue.example"))
    }

    // #2560, the row of that table #2549 left standing. Measured 2026-08-12 by counting a rendered card:
    // a contact with NO name had its address printed twice, because the contact line falls back to the
    // address as the contact's identity and the Contacts block below prints it again as it must (#2015).
    // The third occurrence, in the opening preview area, went with the block #2545 removed.
    //
    // Counted rather than pattern-matched on the source, because "how many times does this card say it" is
    // the actual question and only a rendered view can answer it.
    @Test func anamelessContactsAddressIsAlsoSaidExactlyOnce() throws {
        let rendered = view(item([contact("info@thevenue.example", nil)]))
        let texts = try allTexts(rendered)
        let said = texts.filter { $0 == "info@thevenue.example" }.count

        #expect(said == 1, "the address appears \(said) times: \(texts)")
    }

    // And the contact line does not become a person glyph over nothing. It stops being the address's second
    // printing and says the thing the address cannot: nobody's name was found, which is what decides
    // whether the greeting can name anyone (#2545).
    @Test func thecontactLineSaysThereIsNoNameRatherThanRepeatingTheAddress() throws {
        let rendered = view(item([contact("info@thevenue.example", nil)]))

        #expect(try allTexts(rendered).contains("No name for this contact"))
    }

    // A contact WITH a name keeps its name on that line: this is the nameless case only.
    @Test func anamedContactsLineIsUnchanged() throws {
        let rendered = view(item([contact("sarah@company.example", "Sarah Chen")]))
        let texts = try allTexts(rendered)

        #expect(texts.contains("Sarah Chen"))
        #expect(!texts.contains("No name for this contact"))
    }

    // Two contacts, the first nameless: the case the table measured at three. Each address is said once.
    @Test func twocontactsOneNamelessSayEachAddressOnce() throws {
        let rendered = view(item([contact("info@thevenue.example", nil),
                                  contact("sarah@company.example", "Sarah Chen")]))
        let texts = try allTexts(rendered)

        #expect(texts.filter { $0 == "info@thevenue.example" }.count == 1,
                "the nameless contact's address appears \(texts.filter { $0 == "info@thevenue.example" }.count) times")
        #expect(texts.filter { $0 == "sarah@company.example" }.count == 1)
    }

    // Two contacts are two distinct addresses: removing a duplicate must not collapse separate recipients
    // into one line, which would be the worse defect (Dan would send to someone he cannot see).
    @Test func twocontactsReadAsTwoAddresses() throws {
        let rendered = view(item([contact("info@thevenue.example", nil),
                                  contact("sarah@company.example", "Sarah Chen")]))
        let texts = try allTexts(rendered)

        #expect(texts.contains("info@thevenue.example"))
        #expect(texts.contains("sarah@company.example"))
        // The NAMED contact is the case #2549 reported, and it reads once even beside a second contact.
        #expect(texts.filter { $0 == "sarah@company.example" }.count == 1,
                "the named contact's address appears \(texts.filter { $0 == "sarah@company.example" }.count) times")
    }
}
