import Testing
import Foundation
import SwiftUI
import SwiftData
import ViewInspector
@testable import Overture

// #2152, the half only a rendered panel can answer.
//
// #2147 made the send refuse when the person who wrote is not among the people the answer would reach, so
// Dan's reply can never quietly go to a colleague instead. The refusal was correct and completely silent:
// the Send button went dead and nothing on screen said why, on exactly the conversation he is least able
// to diagnose. A guard and the sentence that explains it are two separate claims, and the decision being
// right in ReplyPanel proves nothing about the panel showing it (L3).
@MainActor
@Suite("The reply panel says why it will not send (#2152)")
struct ReplyPanelRefusalOnScreenTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // Dan's real row, measured on the live store (#2151): he pitched nbecker@ and Nicole answered from
    // nicolebecker@, an address on no contact of this show.
    private func panel(writer: String?, gmailConnected: Bool = true) throws -> ReplyPanelSheet {
        let ctx = ModelContext(try container())
        let p = Prospect(naturalKey: "k", groupName: "Every Voice Choirs", discipline: "choral",
                         venue: "Merkin Hall", performanceDate: "2026-10-31", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 8, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
        let r = Recipient(id: "nbecker@everyvoicechoirs.org", email: "nbecker@everyvoicechoirs.org",
                          provenance: .act)
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.sendState = .sent
        r.gmailThreadId = "t"
        r.replied = true
        r.replyFromAddress = writer
        r.lastReplyText = "Tuesday works for us."
        r.replyAudience = ["nbecker@everyvoicechoirs.org"]
        p.setRecipients([r])
        return ReplyPanelSheet(prospect: p, recipient: r, gmailConnected: gmailConnected)
    }

    private func texts(_ view: ReplyPanelSheet) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // The sentence is on the panel, and it names BOTH addresses: the one that wrote and the one the
    // answer would reach. Asserted on the addresses themselves rather than on a copy constant, so
    // renaming the constant cannot make this vacuous while the panel goes silent again.
    @Test func theRefusedSendNamesWhoWroteAndWhoTheReplyWouldReach() throws {
        let shown = try texts(panel(writer: "nicolebecker@everyvoicechoirs.org"))
        let reason = shown.first { $0.contains("nicolebecker@everyvoicechoirs.org")
                                   && $0.contains("won't send") }
        #expect(reason != nil, "the panel refuses this send and must say why. Shown: \(shown)")
        #expect(reason?.contains("nbecker@everyvoicechoirs.org") == true,
                "the line must name the address the reply would go to instead")
    }

    // A disconnected Gmail is stated on screen too, not left in a tooltip nothing at rest reveals (L49).
    @Test func aDisconnectedGmailIsStatedOnThePanelNotOnlyInATooltip() throws {
        let shown = try texts(panel(writer: "nbecker@everyvoicechoirs.org", gmailConnected: false))
        #expect(shown.contains(GmailCopy.notConnected))
    }

    // And a panel with nothing to explain carries no refusal line at all, so the sentence cannot become
    // furniture that is always there and therefore never read.
    @Test func aPanelWithNothingToExplainShowsNoRefusalAtAll() throws {
        let shown = try texts(panel(writer: "nbecker@everyvoicechoirs.org"))
        #expect(!shown.contains { $0.contains("won't send it") })
        #expect(!shown.contains(GmailCopy.notConnected))
    }
}
