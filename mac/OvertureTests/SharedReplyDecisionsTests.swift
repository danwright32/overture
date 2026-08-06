import Testing
import Foundation
import SwiftData

// #2145, step one: the reply panel's decisions taken off `Recipient` and onto the seam both entities
// already conform to, plus the two things an inquiry needs that a show never did.
//
// The screens are still separate at this point. This is deliberately the pure half, so the rules can be
// wrong here and caught here, rather than discovered while two views are being merged.
@MainActor
@Suite("The reply decisions work for a show and an inquiry alike (#2145)")
struct SharedReplyDecisionsTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func inquiry(_ ctx: ModelContext) -> Inquiry {
        let i = Inquiry(source: .contactForm, inquirerName: "Marta Reyes", inquirerEmail: "marta@example.org",
                        eventName: "Winter recital", notes: "Found you through the Merkin listing.")
        ctx.insert(i)
        return i
    }

    private func contact(_ ctx: ModelContext) -> Recipient {
        let r = Recipient(id: "c@x.org", email: "c@x.org", provenance: .act)
        ctx.insert(r)
        return r
    }

    // MARK: their words, through the seam

    @Test func anInquirysOwnReplyTextIsReadThroughTheSeam() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        i.lastReplyText = "  Thursday would suit us better.  "
        #expect(ReplyPanel.theirWords(i) == "Thursday would suit us better.")
    }

    // MARK: the sentence that would have lied

    // The commonest inquiry there is: Dan logged a hire enquiry by hand and has not answered it yet. There
    // is no inbound Gmail message and no thread, so "Overture didn't capture what they wrote. Their message
    // is in Gmail." would claim a message exists and name a place it is not. Nothing is missing here, so
    // the surface says nothing (L11).
    @Test func anInquiryThatHasReceivedNothingSaysNothingAboutAMissingMessage() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        #expect(!i.replied)
        #expect(i.repliedAt == nil)
        #expect(ReplyPanel.missingWordsReason(i) == nil)
    }

    // Once they HAVE written, the two existing reasons are unchanged: a reply Overture never looked at,
    // and one it read and could not decode.
    @Test func anInquiryThatWroteBackWithNoStoredTextStillExplainsWhy() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        i.replied = true
        i.repliedAt = Date(timeIntervalSince1970: 1_000)
        #expect(ReplyPanel.missingWordsReason(i) == ReplyPanelCopy.noCapturedWords)

        i.replyTextCheckedAt = Date(timeIntervalSince1970: 2_000)
        #expect(ReplyPanel.missingWordsReason(i) == ReplyPanelCopy.unreadableWords)
    }

    // A show's contact is unaffected: it only ever reaches this surface with a reply in hand, and the
    // stamp that proves one arrived is what the new case keys on.
    @Test func aShowsContactWithAReplyIsUnchanged() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.replied = true
        r.repliedAt = Date(timeIntervalSince1970: 1_000)
        #expect(ReplyPanel.missingWordsReason(r) == ReplyPanelCopy.noCapturedWords)
    }

    // An answered inquiry has `replied` cleared by the send, so the arrival stamp is what has to carry
    // the fact that they ever wrote. Keying on `replied` alone would make an answered conversation claim
    // nothing was ever received.
    @Test func anAnsweredInquiryStillCountsAsHavingReceivedSomething() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        i.repliedAt = Date(timeIntervalSince1970: 1_000)
        i.replied = false
        #expect(ReplyPanel.missingWordsReason(i) == ReplyPanelCopy.noCapturedWords)
    }

    // A row carrying the replied FLAG has received something by definition, whether or not the arrival
    // was ever timestamped. Detection sets both together, but a row that has only the flag must not fall
    // into the "nothing was ever received" case and go silent about a reply it is holding.
    @Test func theRepliedFlagAloneCountsAsHavingReceivedSomething() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.replied = true
        #expect(r.repliedAt == nil)
        #expect(ReplyPanel.missingWordsReason(r) == ReplyPanelCopy.noCapturedWords)
    }

    // So does a row the repair pass has already looked at: it only ever looks at threads holding an
    // inbound message.
    @Test func aRowTheRepairPassCheckedCountsAsHavingReceivedSomething() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.replyTextCheckedAt = Date(timeIntervalSince1970: 2_000)
        #expect(ReplyPanel.missingWordsReason(r) == ReplyPanelCopy.unreadableWords)
    }

    // MARK: the subject an inquiry can edit

    // An inquiry's subject is typed, so it can be emptied. Without its own refusal the shared rule would
    // let Send be pressed on a message that cannot be built, and report a failure for something the app
    // knew was impossible before he pressed it (L67).
    @Test func aBlankTypedSubjectRefusesTheSend() {
        #expect(ReplyPanel.refusal(body: "Thursday works.", subject: "  ", audience: ["m@x.org"],
                                   gmailConnected: true, writer: "m@x.org") == .noSubject)
    }

    @Test func aTypedSubjectWithWordsInItDoesNotRefuse() {
        #expect(ReplyPanel.refusal(body: "Thursday works.", subject: "Re: your inquiry",
                                   audience: ["m@x.org"], gmailConnected: true, writer: "m@x.org") == nil)
    }

    // A show has no subject to type: it answers into a Gmail thread that already has one. Nil says the
    // entity has no editable subject, which is a different thing from an empty one.
    @Test func anEntityWithNoEditableSubjectIsNeverRefusedForIt() {
        #expect(ReplyPanel.refusal(body: "Thursday works.", subject: nil, audience: ["m@x.org"],
                                   gmailConnected: true, writer: "m@x.org") == nil)
    }

    // Ordering: the subject sits above the body on screen, so an empty one is named first when both are
    // empty. Both are things he can see, which is why neither gets a sentence beside the button.
    @Test func anEmptySubjectIsNamedBeforeAnEmptyBody() {
        #expect(ReplyPanel.refusal(body: "", subject: "", audience: ["m@x.org"],
                                   gmailConnected: true, writer: "m@x.org") == .noSubject)
    }

    // The refusals that outrank it still do. A disconnected Gmail is not a subject problem.
    @Test func aDisconnectedGmailStillOutranksTheSubject() {
        #expect(ReplyPanel.refusal(body: "", subject: "", audience: ["m@x.org"],
                                   gmailConnected: false, writer: nil) == .gmailDisconnected)
    }

    // And it says nothing beside the button, for the same reason an empty body says nothing: he is
    // looking straight at the empty field. A line that is always on screen stops being read (#843).
    @Test func theSubjectRefusalSaysNothingBesideTheButton() {
        #expect(ReplyPanelCopy.refusalLine(.noSubject) == nil)
    }
}
