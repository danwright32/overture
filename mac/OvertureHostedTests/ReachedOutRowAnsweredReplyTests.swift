import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #2919: the rendered half. `AnsweredReplyNoteTests` decides what the sentence IS; this is the row on
// screen, in EVERY state it can be in.
//
// Reading only the populated branch is how #1547 shipped: a sentence that was correct, tested and inside
// the branch nobody was in, over a heading that then read as the opposite of what it meant. So all four
// states the reached-out row can render are here, and each one says what it draws and what it does not.
@Suite("The reached-out row says a reply was answered (#2919)")
struct ReachedOutRowAnsweredReplyTests {

    private let writerAddress = "rowan@aurorastrings.example"
    private func day(_ s: String) -> Date { EasternDate.date(from: s)! }
    private var now: Date { day("2026-08-18") }

    private func show() -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music",
                         venue: "Rivermill Hall", performanceDate: "2026-11-20", sourceListingURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.sourceIds = ["hall"]
        return p
    }

    private func contact(_ p: Prospect) -> Recipient {
        let r = Recipient(id: writerAddress, email: writerAddress, name: "Rowan", provenance: .act)
        r.sendState = .sent
        r.sentAt = day("2026-08-01")
        r.gmailMessageId = "m1"
        r.gmailThreadId = "t1"
        r.sendGroupId = "g"
        p.setRecipients([r])
        p.sentAt = r.sentAt
        return r
    }

    private func drawn(_ p: Prospect, _ r: Recipient) -> some View {
        QueueView(deepLinkedKey: .constant(nil), deepLinkedKeys: .constant(nil))
            .reachedOutRow((prospect: p, recipient: r, next: now), now: now, since: nil,
                           sourceCalendars: [:])
    }

    private func texts(_ view: some View) -> [String] {
        ((try? view.inspect().findAll(ViewType.Text.self)) ?? []).compactMap { try? $0.string() }
    }

    private let answeredLine = "Replied Aug 14, you answered Aug 15"

    private func theyWrote(_ r: Recipient) {
        r.replied = true
        r.repliedAt = day("2026-08-14")
        r.inboundReplySentAt = day("2026-08-14")
        r.replyFromAddress = writerAddress
        r.replyFromName = "Rowan Ellis"
        r.lastReplyId = "reply-1"
    }

    // State one: nobody ever wrote. The resting row, unchanged, and it must not gain a sentence about a
    // conversation that never happened.
    @Test func aPitchNobodyRepliedToSaysNothingAboutAConversation() {
        let p = show()
        let r = contact(p)
        let lines = texts(drawn(p, r))

        #expect(lines.contains("Aurora Strings"))
        #expect(!lines.contains(where: { $0.hasPrefix("Replied ") }))
        #expect(!lines.contains(where: { $0.contains("you answered") }))
    }

    // State two: they wrote and Dan has not answered. The Answer control and the marked writer already
    // report that, so the row does not restate it in a line beside them (#843).
    @Test func aReplyWaitingOnHimIsReportedByTheAnswerControlAndNotByASecondSentence() {
        let p = show()
        let r = contact(p)
        theyWrote(r)
        let view = drawn(p, r)

        #expect(ReplyPanel.isOffered(for: r, in: p))
        #expect(texts(view).contains(ReplyPanelCopy.answer))
        #expect(!texts(view).contains(where: { $0.contains("you answered") }))
    }

    // State three: the defect. They wrote, he answered, and the row used to go back to looking exactly
    // like state one.
    @Test func anAnsweredReplyIsSaidOnTheRow() {
        let p = show()
        let r = contact(p)
        theyWrote(r)
        r.replyHandledAt = day("2026-08-15")
        let view = drawn(p, r)

        #expect(!ReplyPanel.isOffered(for: r, in: p))   // the control that used to be the only sign is gone
        #expect(texts(view).contains(answeredLine))
    }

    // And the row it sits on is otherwise the row he already reads: the line is an addition, never a
    // replacement for anything, and the writer's own address is still on screen and still marked, which is
    // why the sentence names nobody.
    @Test func theAnsweredRowStillCarriesTheShowAndTheMarkedWriter() {
        let p = show()
        let r = contact(p)
        theyWrote(r)
        r.replyHandledAt = day("2026-08-15")
        let lines = texts(drawn(p, r))

        #expect(lines.contains("Aurora Strings"))
        #expect(lines.contains(writerAddress))
        #expect(ReplyIdentity.rowAudience(for: r, in: p).responder == writerAddress)
    }

    // State four: closed out. The show leaves this stage entirely, and while the departure plays it is a
    // different view, so the answered line is not on screen at all rather than sitting under an ending.
    @Test func aClosedOutShowDrawsTheDepartureRowAndNotTheAnsweredLine() {
        let p = show()
        let r = contact(p)
        theyWrote(r)
        r.replyHandledAt = day("2026-08-15")
        p.showOutcome = .neverHeardBack

        #expect(!ReachedOutQueue.isInPlay(r, of: p))
        let departure = ClosedOutDepartureRow(item: QueueItem(p))
        #expect(!texts(departure).contains(answeredLine))
    }

    // They wrote AGAIN after he answered. The row goes back to asking, and the answered line comes down
    // with it, so the two states can never be on screen at once.
    @Test func aSecondReplyPutsTheRowBackToAskingAndTakesTheLineDown() {
        let p = show()
        let r = contact(p)
        theyWrote(r)
        r.replyHandledAt = day("2026-08-13")   // he answered, then they wrote again on the 14th
        let view = drawn(p, r)

        #expect(r.hasUnhandledReply)
        #expect(texts(view).contains(ReplyPanelCopy.answer))
        #expect(!texts(view).contains(where: { $0.contains("you answered") }))
    }
}
