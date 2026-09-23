import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #4042: the warning that BLOCKS a send, naming the show and the night it is about.
//
// Here as well as in `ADuplicateWarningNamesTheShowTests`, which asserts the sentence and the journey
// from the recipient to the card, because this is the last link and the one neither of those can
// reach: the review screen reads `duplicateOfTitle` and `duplicateOfNight` off the snapshot, and a
// screen passing the wrong field, or none, would leave both of those green (L718, #1995).
@MainActor
@Suite("The review screen names the show its duplicate warning is about (#4042)")
struct DraftReviewViewDuplicateWarningTests {
    private func contact(title: String?, night: String?) -> RecipientSnapshot {
        var snapshot = RecipientSnapshot(id: "r", name: "Ana Ruiz", email: "ana@example.org", role: nil,
                                         provenance: .presenter, sendState: .pending, replied: false,
                                         lastReplyText: nil, resolution: nil, bounced: false,
                                         outcomeSource: nil)
        snapshot.looksLikeDuplicateContact = true
        snapshot.duplicateOfTitle = title
        snapshot.duplicateOfNight = night
        return snapshot
    }

    private func item(_ contact: RecipientSnapshot) -> QueueItem {
        var item = QueueItem(id: "k", groupName: "Legends: A New Musical", discipline: "theater",
                             venue: "The Players Theatre", performanceDate: "2026-10-04",
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 6,
                             tier: "mid", fitReason: "r", matchedClientName: nil,
                             possibleMatchSource: nil, possibleMatchName: nil,
                             status: .drafted, draftSubject: "S", draftBody: "Hi",
                             hasPendingRecipient: true)
        item.contacts = [contact]
        return item
    }

    private func texts(_ item: QueueItem) throws -> [String] {
        let view = DraftReviewView(item: item, onUnapprove: {}, onSaveDraft: { _, _ in },
                                   gmailConnected: true, outboundSendSince: nil)
        return try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    @Test func thewarningNamesTheShowAndTheNight() throws {
        let found = try texts(item(contact(title: "The ATF Cabaret", night: "2026-10-03")))
        #expect(found.contains { $0.contains("Ana Ruiz may already be pitched for The ATF Cabaret on ") },
                "the screen drew a warning that names neither the show nor the night: \(found)")
    }

    // THE ROW MERGED AWAY between prep and review, which resolves to nothing: the screen keeps the
    // wording it has always had rather than naming a card Dan cannot open (L200, L11).
    @Test func anunresolvedKeyKeepsTheOlderWording() throws {
        let found = try texts(item(contact(title: nil, night: nil)))
        #expect(found.contains {
            $0 == "Ana Ruiz may already be pitched for a show at this venue; blocked from sending."
        }, "the fallback sentence is not what the screen drew: \(found)")
    }

    // Both themes, for the same reason every other card note is checked in both (L606, L569).
    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func thewarningRendersInBothThemes(_ scheme: ColorScheme) throws {
        let view = DraftReviewView(item: item(contact(title: "The ATF Cabaret", night: "2026-10-03")),
                                   onUnapprove: {}, onSaveDraft: { _, _ in },
                                   gmailConnected: true, outboundSendSince: nil)
            .environment(\.colorScheme, scheme)
        let found = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(found.contains { $0.contains("The ATF Cabaret") })
    }
}
