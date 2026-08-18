import Testing
import Foundation
import SwiftUI
import SwiftData
import ViewInspector
@testable import Overture

// #2546, the half only a rendered view can answer.
//
// ControlRefusalReasonTests proves each gate HAS a reason and that the reason and the disabling agree.
// It cannot see whether the sentence reaches the screen, and that is the entire defect: every one of
// these controls already computed everything it needed to explain itself and threw the answer away
// (L3, built is not wired).
//
// Every assertion here goes through ControlRefusalLine.identifier rather than searching the tree for
// the sentence. That is deliberate and it is the difference between a real test and a green one:
// `.help()` puts its string into the view hierarchy too, so a text search passes with the visible line
// deleted and only the tooltip left, which is exactly the state L49 calls a defect. The identifier is
// carried only by the visible line.
@MainActor
@Suite("A refusing control says why, on screen (#2546)")
struct ControlRefusalOnScreenTests {

    // The refusal lines a person can actually SEE in this view, tooltips excluded by construction.
    private func visibleRefusals(_ view: some View) throws -> [String] {
        try view.inspect()
            .findAll(ViewType.Text.self,
                     where: { (try? $0.accessibilityIdentifier()) == ControlRefusalLine.identifier })
            .map { try $0.string() }
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // MARK: - FollowUpsView's nudge and closing note

    private func followUpRow(email: String?) -> FollowUp.DueRecipient {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2026-08-01",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .contacted)
        let r = Recipient(id: "act", email: email, name: "Emma", provenance: .act)
        r.sendState = .sent
        return FollowUp.DueRecipient(prospect: p, recipient: r)
    }

    // The row Dan actually meets: a contact whose address was never found. Before this the button was
    // dead and the tooltip read "Review and send", which is the wrong sentence rather than no sentence.
    @Test func aNudgeToAContactWithNoAddressSaysSoOnTheRow() throws {
        let view = FollowUpsView(gmailConnectedOverride: true)
        let shown = try visibleRefusals(view.row(followUpRow(email: nil), since: nil, sourceCalendars: [:]))
        #expect(shown == [SendGate.noAddressReason], "shown: \(shown)")
    }

    // The other cause, on the same button, saying something different.
    @Test func aNudgeWithGmailDisconnectedNamesGmailInstead() throws {
        let view = FollowUpsView(gmailConnectedOverride: false)
        let shown = try visibleRefusals(view.row(followUpRow(email: "emma@aurora.example"), since: nil, sourceCalendars: [:]))
        #expect(shown == [GmailCopy.notConnected], "shown: \(shown)")
    }

    // And a row that can send carries no line at all, so the sentence cannot become furniture that is
    // always on screen and therefore never read (#843).
    @Test func aSendableNudgeRowShowsNoRefusalAtAll() throws {
        let view = FollowUpsView(gmailConnectedOverride: true)
        #expect(try visibleRefusals(view.row(followUpRow(email: "emma@aurora.example"),
                                             since: nil, sourceCalendars: [:])).isEmpty)
    }

    // MARK: - ReplyConversationView's Send reply

    private func replyRow(email: String?, gmailConnected: Bool) throws -> ReplyConversationView {
        let ctx = ModelContext(try container())
        let r = Recipient(id: "act", email: email, name: "Emma", provenance: .act)
        r.sendState = .sent
        r.replied = true
        r.replyDraftBody = "Thanks, Tuesday works."
        ctx.insert(r)
        return ReplyConversationView(contact: RecipientSnapshot(r), lintTitle: "Aurora Strings",
                                     knownsDate: true, knownsVenue: true,
                                     gmailConnected: gmailConnected, sendingSince: nil)
    }

    // #2546 added the address to this gate. It used to send, fail inside SendService's own blank-address
    // refusal, and report nothing at all.
    @Test func aReplyToAContactWithNoAddressSaysSoRatherThanFailingSilently() throws {
        let shown = try visibleRefusals(replyRow(email: nil, gmailConnected: true))
        #expect(shown == [SendGate.noAddressReason], "shown: \(shown)")
    }

    @Test func aReplyWithGmailDisconnectedSaysSoOnScreenNotOnlyInATooltip() throws {
        let shown = try visibleRefusals(replyRow(email: "emma@aurora.example", gmailConnected: false))
        #expect(shown == [GmailCopy.notConnected], "shown: \(shown)")
    }

    @Test func aSendableReplyShowsNoRefusalAtAll() throws {
        #expect(try visibleRefusals(replyRow(email: "emma@aurora.example",
                                             gmailConnected: true)).isEmpty)
    }

    // MARK: - InquiryIntakeSheet's Save

    // The sheet opens with every box empty, so this is the state Dan meets first. Compared against the
    // domain's own answer rather than a second copy of the sentence typed in here, so the screen cannot
    // drift from the gate.
    @Test func aFreshlyOpenedInquirySheetSaysWhySaveIsRefusing() throws {
        let sheet = InquiryIntakeSheet()
            .modelContainer(try container())
            .environment(ActionFeedback())
        let expected = InquiryIntake.reasonSaveIsDisabled(name: "")
        #expect(expected != nil)
        #expect(try visibleRefusals(sheet) == [expected!])
    }

    // The clause that reports on a press nobody has made must not ride along onto a sheet at rest.
    @Test func theInquirySheetDoesNotReportOnASaveThatHasNotHappened() throws {
        let sheet = InquiryIntakeSheet()
            .modelContainer(try container())
            .environment(ActionFeedback())
        let shown = try visibleRefusals(sheet)
        // Non-empty first: a sheet showing nothing would satisfy the loop below without saying a word,
        // and this test would then be green over the silence it exists to rule out.
        #expect(!shown.isEmpty)
        for line in shown {
            #expect(!line.lowercased().contains("nothing was saved"),
                    "the opened sheet says \"\(line)\" before anything has been pressed")
        }
    }
}
