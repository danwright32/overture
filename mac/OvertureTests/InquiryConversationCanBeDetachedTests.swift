import Testing
import Foundation

// #2797: a conversation attached to the wrong INQUIRY could not be undone from inside the app.
//
// #2712 attaches an inquiry's conversation AUTOMATICALLY, without asking, because the match is address
// identity rather than a guess. That is the right call, and it is exactly what makes the missing undo
// the remaining risk: a wrong attach had no way back at all (L9, L97).
//
// TWO THINGS TURNED OUT TO BE WRONG WITH THE ISSUE'S PREMISE, and both are covered here rather than
// worked around. `DetachConversation` is `Recipient`-typed, which the issue says. What it does not say
// is that the function has NO CALLER anywhere in `mac/Overture`: it is reached only by its own tests. So
// the pitch side had no undo either, and generalising the type alone would have produced a second
// unreachable function beside the first (L3). The control is wired for both here.
//
// WHAT AN INQUIRY DETACH HAS TO UNDO is derived from what the attach WRITES, not from the pitch
// version's field list. An inquiry has no `attachedThreadSubject`, no recipients to unfreeze and no
// address of the attach's making, and it has one the pitch does not: `sentAt`, which the attach fills in
// from Dan's own message on the thread when the inquiry had none. That one needs its own marker, for the
// reason `attachWroteAddress` exists: a value that was already there was never the detach's to remove.
@MainActor
@Suite("A conversation attached to the wrong inquiry can be detached (#2797)")
struct InquiryConversationCanBeDetachedTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func attachedInquiry(wroteSentAt: Bool = true, answeredAfter: Bool = false) -> Inquiry {
        let i = Inquiry(source: .directEmail, inquirerName: "Nessa Halloway",
                        inquirerEmail: "nessa@example.com", eventName: "An Evening of Songs",
                        createdAt: now.addingTimeInterval(-5 * 86_400))
        i.gmailThreadId = "t-1"
        i.conversationAttachedAt = now
        i.sentAt = now.addingTimeInterval(-2 * 86_400)
        i.attachWroteSentAt = wroteSentAt
        i.replied = true
        i.repliedAt = now.addingTimeInterval(-3_600)
        i.lastReplyId = "m-1"
        i.lastReplyText = "What would this cost?"
        i.replyFromAddress = "nessa@example.com"
        i.replyFromName = "Nessa Halloway"
        i.inboundReplyMessageId = "mid-1"
        i.inboundReplySentAt = now.addingTimeInterval(-3_600)
        i.replyTextCheckedAt = now
        if answeredAfter { i.replyHandledAt = now.addingTimeInterval(60) }
        return i
    }

    // MARK: - The undo

    @Test func detachingClearsTheLinkAndEverythingDetectionWrote() {
        let i = attachedInquiry()
        let outcome = DetachConversation.detach(i, now: now.addingTimeInterval(120),
                                                omniFocusEnabled: false)

        guard case .detached = outcome else {
            Issue.record("a wrongly attached inquiry could not be detached")
            return
        }
        #expect(i.gmailThreadId == nil)
        #expect(i.conversationAttachedAt == nil)
        #expect(i.replied == false)
        #expect(i.repliedAt == nil)
        #expect(i.lastReplyId == nil)
        #expect(i.lastReplyText == nil)
        #expect(i.replyFromAddress == nil)
        #expect(i.replyFromName == nil)
        #expect(i.inboundReplyMessageId == nil)
        #expect(i.inboundReplySentAt == nil)
        #expect(i.replyTextCheckedAt == nil)
        #expect(i.replyHandledAt == nil)
    }

    // The one field the pitch version has no equivalent of. The attach fills `sentAt` from Dan's own
    // message on the thread when the inquiry carries none, so a detach that left it behind would leave
    // the row claiming he answered on a conversation that is no longer attached to it.
    @Test func detachingTakesBackTheSendDateTheAttachSuppliedX() {
        let i = attachedInquiry(wroteSentAt: true)
        _ = DetachConversation.detach(i, now: now.addingTimeInterval(120), omniFocusEnabled: false)
        #expect(i.sentAt == nil)
        #expect(i.attachWroteSentAt == false)
    }

    // And leaves alone one the attach found already there. A value that was not the attach's to write is
    // not the detach's to remove, which is the rule `attachWroteAddress` exists for on the pitch side.
    @Test func adateTheAttachDidNotWriteSurvivesTheDetach() {
        let i = attachedInquiry(wroteSentAt: false)
        let his = i.sentAt
        _ = DetachConversation.detach(i, now: now.addingTimeInterval(120), omniFocusEnabled: false)
        #expect(i.sentAt == his, "the detach removed a send date it never wrote")
    }

    // MARK: - When it refuses

    @Test func aninquiryWithNoLinkedConversationRefuses() {
        let i = Inquiry(source: .directEmail, inquirerName: "Nessa Halloway",
                        inquirerEmail: "nessa@example.com", eventName: "An Evening of Songs",
                        createdAt: now)
        guard case .refused(let reason) = DetachConversation.detach(i, now: now,
                                                                    omniFocusEnabled: false) else {
            Issue.record("detaching an inquiry with nothing linked reported success")
            return
        }
        #expect(reason == DetachConversationCopy.nothingLinked)
    }

    // Answered SINCE the attach, which is the pitch version's rule and for its reason: a message that has
    // GONE OUT onto a stranger's conversation cannot be taken back, and a detach claiming otherwise
    // would be undoing something it cannot undo (L38).
    @Test func aninquiryAnsweredSinceTheAttachRefuses() {
        let i = attachedInquiry(answeredAfter: true)
        guard case .refused(let reason) = DetachConversation.detach(i, now: now.addingTimeInterval(120),
                                                                    omniFocusEnabled: false) else {
            Issue.record("an inquiry answered since the attach was detached anyway")
            return
        }
        #expect(reason == DetachConversationCopy.alreadyAnswered)
    }

    // An answer stamped by the attach ITSELF is not an answer since the attach. #2715's stamp lands when
    // the thread's newest message was already Dan's, and counting it would make a conversation he had
    // already dealt with instantly and permanently un-undoable, which is the trap this exists to avoid.
    @Test func ananswerStampedByTheAttachItselfDoesNotBlockTheDetach() {
        let i = attachedInquiry()
        i.replyHandledAt = now
        guard case .detached = DetachConversation.detach(i, now: now.addingTimeInterval(120),
                                                         omniFocusEnabled: false) else {
            Issue.record("the attach's own answered stamp blocked the undo it was supposed to allow")
            return
        }
    }

    // MARK: - Built is not wired (L3)

    // The whole reason this issue exists. `DetachConversation.detach` had no caller in `mac/Overture` at
    // all before this: it was reached only by its own tests, so the PITCH side had no undo either.
    @Test func bothSurfacesReachTheDetach() {
        for file in ["Overture/UI/InquiryMutations.swift", "Overture/UI/ProspectMutations.swift"] {
            let source = SourceGuardHelper.source(file)
            #expect(!source.isEmpty)
            #expect(source.contains("DetachConversation.detach("),
                    Comment(rawValue: "\(file) never reaches the detach, so its undo is unreachable (#2797, L3)"))
        }
    }

    @Test func theinquiryRowOffersTheUndo() {
        let source = SourceGuardHelper.source("Overture/UI/InquiryRowView.swift")
        #expect(!source.isEmpty)
        // The BUTTON, not merely the string. `DetachConversationCopy.controlHelp` has
        // `DetachConversationCopy.control` as a prefix, so a bare substring search stayed green with the
        // button's label replaced and only the tooltip left (L135). Measured: mutate.sh said SURVIVED.
        #expect(SourceGuardHelper.containsCode(
            "Button(DetachConversationCopy.control) { onDetachConversation() }", in: source),
                "an inquiry's linked conversation cannot be unlinked from the row that shows it (#2797)")
        #expect(source.contains("DetachConversationCopy.controlHelp"),
                "the control carries no explanation of what unlinking takes back")
    }
}
