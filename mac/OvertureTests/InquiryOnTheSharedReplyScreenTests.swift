import Testing
import Foundation
import SwiftData

// #2145, step five: an inquiry answered through the same screen as a scouted show.
//
// This is where the gaps close. Answering a hire inquiry had no sight of the message being answered, no
// stated reason when Send refused, and no confirmation of what was about to go out, so the signature the
// send composes on reached real people having been read by nobody. None of that was a decision; it was
// two files drifting.
@MainActor
@Suite("An inquiry answers through the shared reply screen (#2145)")
struct InquiryOnTheSharedReplyScreenTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func inquiry(_ ctx: ModelContext, email: String? = "marta@example.org") -> Inquiry {
        let i = Inquiry(source: .contactForm, inquirerName: "Marta Reyes", inquirerEmail: email,
                        eventName: "Winter recital", notes: "Found you through the Merkin listing.")
        ctx.insert(i)
        return i
    }

    private func composition(_ i: Inquiry, _ ctx: ModelContext) -> ReplyComposition {
        .answering(i, context: ctx, feedback: ActionFeedback())
    }

    // MARK: what the screen is told

    @Test func itNamesTheInquirerAndAnswersTheirAddress() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        let c = composition(i, ctx)
        #expect(c.title.contains("Marta Reyes"))
        #expect(c.audience == ["marta@example.org"])
    }

    // Dan's own note about where the enquiry came from is context he wrote for himself, and it belongs on
    // the screen where he answers it.
    @Test func hisOwnNoteRidesAlongUnderTheTitle() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        #expect(composition(i, ctx).subtitle == "Found you through the Merkin listing.")
    }

    // An inquiry has a subject to type, and it starts where it always started.
    @Test func theSubjectIsHisToTypeAndStartsWhereItAlwaysDid() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        #expect(composition(i, ctx).editableSubject == InquiryCopy.replySubjectDefault)
    }

    // No AI drafter and no contact-list controls: an inquiry has no draft fields and is one person, so
    // those controls are ABSENT rather than present and inert.
    @Test func itOffersNoDrafterAndNoContactListControls() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        let c = composition(i, ctx)
        #expect(c.aiDraft == nil)
        #expect(c.audienceControls == nil)
    }

    // MARK: the gaps this closes

    // The refusal is stated, through the same rule a show goes through, rather than a button going quietly
    // dead. An inquiry logged with no address is the case Dan cannot otherwise diagnose.
    @Test func anInquiryWithNoAddressRefusesTheSendThroughTheSharedRule() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx, email: nil)
        #expect(composition(i, ctx).refusal(body: "Thursday works.", gmailConnected: true) == .noAudience)
    }

    // The subject check an inquiry has always had survives the move, now as a stated refusal.
    @Test func aBlankSubjectStillRefusesTheSend() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        var c = composition(i, ctx)
        c = ReplyComposition(title: c.title, subtitle: c.subtitle, contact: c.contact,
                             editableSubject: "  ", aiDraft: nil, audienceControls: nil,
                             confirmation: c.confirmation, send: c.send)
        #expect(c.refusal(body: "Thursday works.", gmailConnected: true) == .noSubject)
    }

    // And what he approves is the message that goes out, signature included, which is the thing an
    // inquiry reply has never shown him.
    @Test func whatHeApprovesIsTheMessageThatGoesOut() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        let c = composition(i, ctx)
        let sig = OutboundSignature(html: "<p>Dan Wright</p>", plainText: "Dan Wright")
        let confirmation = try #require(SendConfirmation(replyTo: c.audience,
                                                         subject: "Re: your inquiry",
                                                         body: "Thursday works.", signature: sig))
        #expect(confirmation.recipient == "marta@example.org")
        #expect(confirmation.body == GmailMessage.previewBody(body: "Thursday works.", signature: sig))
    }

    // The subject he TYPED is the one confirmed, not the default it started at, or the sheet would show
    // one subject while another shipped (L64).
    @Test func theSubjectHeTypedIsTheOneConfirmed() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        let c = composition(i, ctx)
        let confirmation = try #require(c.confirmation("Thursday works.", "Re: the recital, and rates"))
        #expect(confirmation.subject == "Re: the recital, and rates")
    }

    // A first reply to an inquiry nobody has written back on says nothing about a missing message,
    // because there is no message and no Gmail thread to point at.
    @Test func aFirstReplySaysNothingAboutAMissingMessage() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        #expect(ReplyPanel.missingWordsReason(composition(i, ctx).contact) == nil)
    }

    // Once they HAVE written, the screen shows what they said, which is the whole reason to answer here.
    @Test func onceTheyWriteBackTheirWordsAreOnTheScreen() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        i.replied = true
        i.repliedAt = Date(timeIntervalSince1970: 1_000)
        i.lastReplyText = "Could you also cover the reception afterwards?"
        #expect(ReplyPanel.theirWords(composition(i, ctx).contact)
                == "Could you also cover the reception afterwards?")
    }
}
