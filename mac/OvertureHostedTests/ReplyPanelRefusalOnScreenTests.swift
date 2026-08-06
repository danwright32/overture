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
    private func panel(writer: String?, gmailConnected: Bool = true,
                       audience: [String]? = nil) throws -> ReplySheet {
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
        r.replyAudience = audience ?? ["nbecker@everyvoicechoirs.org"]
        p.setRecipients([r])
        return ReplySheet(composition: .answering(r, of: p, context: ctx, feedback: ActionFeedback()),
                          gmailConnected: gmailConnected)
    }

    private func texts(_ view: ReplySheet) throws -> [String] {
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

    // MARK: #2155, who wrote and taking somebody off

    // Dan's exact complaint on the live panel: "it's also not clear which email sent the message I'm
    // reading". Three addresses, and the one that wrote is marked on screen rather than left to be
    // inferred from the order.
    @Test func thePanelMarksWhichOfTheAddressesWroteTheMessage() throws {
        let shown = try texts(panel(writer: "nicolebecker@everyvoicechoirs.org",
                                    audience: ["nicolebecker@everyvoicechoirs.org",
                                               "chelsea@everyvoicechoirs.org",
                                               "nbecker@everyvoicechoirs.org"]))
        #expect(shown.contains("nicolebecker@everyvoicechoirs.org"))
        #expect(shown.contains("chelsea@everyvoicechoirs.org"))
        #expect(shown.contains(ReplyPanelCopy.wroteThis), "the writer must be identified. Shown: \(shown)")
    }

    // A remove control per address, and its label states BOTH halves of what pressing it does, because an
    // icon-only button's label is the only place the second half is written down.
    @Test func everyAddressCarriesARemoveControlThatSaysWhatItDoes() throws {
        let view = try panel(writer: "nicolebecker@everyvoicechoirs.org",
                             audience: ["nicolebecker@everyvoicechoirs.org",
                                        "chelsea@everyvoicechoirs.org"])
        for address in ["nicolebecker@everyvoicechoirs.org", "chelsea@everyvoicechoirs.org"] {
            let label = ReplyPanelCopy.removeFromReply(address)
            #expect((try? view.inspect().find(button: label)) != nil
                    || (try? view.inspect().find(viewWithAccessibilityLabel: label)) != nil,
                    "no remove control for \(address)")
        }
    }

    // The last address has none, because emptying the audience would fall back to the contact's own
    // address and deliver the reply to somebody just taken off it.
    @Test func theLastRemainingAddressHasNoRemoveControl() throws {
        let view = try panel(writer: "nbecker@everyvoicechoirs.org",
                             audience: ["nbecker@everyvoicechoirs.org"])
        let label = ReplyPanelCopy.removeFromReply("nbecker@everyvoicechoirs.org")
        #expect((try? view.inspect().find(viewWithAccessibilityLabel: label)) == nil)
    }

    // MARK: #2149, a message Overture could not read

    // A reply it read and could not decode is a different state from one it never looked at, and the panel
    // has to show the sentence that is true of THIS row. Rendered, because the decision being right in
    // ReplyPanel proves nothing about which words reach the screen (L3).
    @Test func aMessageThatCouldNotBeReadSaysSoOnThePanel() throws {
        let view = try panel(writer: "nbecker@everyvoicechoirs.org")
        view.composition.contact.lastReplyText = nil
        view.composition.contact.replyTextCheckedAt = Date(timeIntervalSince1970: 10)

        let shown = try texts(view)
        #expect(shown.contains(ReplyPanelCopy.unreadableWords), "Shown: \(shown)")
        #expect(!shown.contains(ReplyPanelCopy.noCapturedWords),
                "a message that was read must not claim nothing was captured")
    }

    // And one nothing has been tried on yet keeps the sentence that is true of it.
    @Test func aReplyNothingHasBeenTriedOnStillSaysNothingWasCaptured() throws {
        let view = try panel(writer: "nbecker@everyvoicechoirs.org")
        view.composition.contact.lastReplyText = nil
        view.composition.contact.replyTextCheckedAt = nil

        let shown = try texts(view)
        #expect(shown.contains(ReplyPanelCopy.noCapturedWords), "Shown: \(shown)")
        #expect(!shown.contains(ReplyPanelCopy.unreadableWords))
    }

    // With the words in hand the panel explains nothing, it just shows them.
    @Test func aReadableReplyExplainsNothingAndShowsTheWords() throws {
        let shown = try texts(panel(writer: "nbecker@everyvoicechoirs.org"))
        #expect(shown.contains("Tuesday works for us."))
        #expect(!shown.contains(ReplyPanelCopy.unreadableWords))
        #expect(!shown.contains(ReplyPanelCopy.noCapturedWords))
    }

    // MARK: #2151, an address on no contact of this show

    // Dan's real row. The panel says the address is not saved here and offers to save it, rather than
    // leaving the mismatch invisible and permanent.
    @Test func anAddressOnNoContactIsSaidAndOfferedOnThePanel() throws {
        let view = try panel(writer: "nicolebecker@everyvoicechoirs.org",
                             audience: ["nicolebecker@everyvoicechoirs.org",
                                        "nbecker@everyvoicechoirs.org"])
        let shown = try texts(view)
        #expect(shown.contains(ReplyPanelCopy.writerNotAContact("nicolebecker@everyvoicechoirs.org")),
                "the panel must say the address is new. Shown: \(shown)")
        #expect((try? view.inspect().find(button: ReplyPanelCopy.saveWriter)) != nil,
                "and offer to save it")
    }

    // A writer Dan actually pitched is the ordinary case and gets neither the sentence nor the offer, so
    // the line cannot become permanent furniture beside every reply.
    @Test func aWriterAlreadyOnTheShowIsNotOfferedForSaving() throws {
        let view = try panel(writer: "nbecker@everyvoicechoirs.org",
                             audience: ["nbecker@everyvoicechoirs.org"])
        #expect((try? view.inspect().find(button: ReplyPanelCopy.saveWriter)) == nil)
        let shown = try texts(view)
        #expect(!shown.contains { $0.contains("isn't saved as a contact") })
    }
}
