import Testing
import Foundation
import SwiftData

// #2675: an inquiry carries the same send problems a prospect's contact does and rendered none of them.
// A field written and never read looks alive to any is-this-used check while the purpose it was added
// for silently never happens (L46).
//
// WHERE THEY GO, which is the decision the issue asks for: on the inquiry's OWN ROW, not folded into the
// shows pill. `.sendThreadingDegraded` is a navigation target whose tap resolves prospect keys, so adding
// inquiries to its number would tell Dan exactly what is wrong and give him nowhere to go (L80), and it
// would say it in the word "shows", which an inquiry is not (L118). The row is where the rest of an
// inquiry's state already lives.
//
// ONE PREMISE IN THE ISSUE WAS WRONG, and correcting it made the change bigger rather than smaller.
// The issue lists `Inquiry.sendError` as a field with a writer and no reader. There is no such field:
// `InquiryReplySender.sendReply` returns `false` and stores NOTHING, so a failed reply left no trace at
// all. The caller shows `.sendFailed` once and that notice clears, while the inquiry stays on screen
// looking unsent with nothing saying why (L126). So the field is added here, written on the failure path
// and cleared on success, exactly as `SendService` does for a prospect.
//
// Sized on the live Release store, 2026-08-13: 0 inquiries hold a `gmailThreadId`, so nothing is wrong on
// screen today. That is why this was not urgent, and also why it would have stayed invisible until the
// first inquiry Dan replies to hit it.
@MainActor
@Suite("An inquiry renders its send problems (#2675)")
struct InquirySendProblemsAreRenderedTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func inquiry(_ ctx: ModelContext) -> Inquiry {
        let i = Inquiry(source: .contactForm, inquirerName: "Nora Vance",
                        inquirerEmail: "nora@example.com", eventName: "A recital")
        i.sentAt = Date()
        ctx.insert(i)
        return i
    }

    private func row(_ i: Inquiry) throws -> InquiryRow {
        try #require(QueueModel.inquiryRows([i], now: Date()).first)
    }

    // MARK: - The three facts reach the row

    @Test func aReplyWhoseThreadCouldNotBeRecordedSaysSo() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        i.threadIdDegraded = true

        #expect(try row(i).threadIdDegraded)
        #expect(InquiryCopy.replyTrackingLostBadge == "Replies can't be tracked")
    }

    @Test func aReplyWhoseMessageIdCouldNotBeReadSaysSo() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        i.threadingDegraded = true

        #expect(try row(i).threadingDegraded)
        #expect(InquiryCopy.threadingDegradedBadge == "A nudge will arrive as a new email")
    }

    // The third, and the one that did not exist. A failed send now leaves a trace on the record rather
    // than only in a notice that clears.
    @Test func aFailedReplyLeavesItsReasonOnTheInquiry() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        i.sendError = "The server refused the message"

        #expect(try row(i).sendError == "The server refused the message")
        // Through the SAME helper the prospect rows use, so the two halves of the funnel cannot word one
        // failure two different ways.
        #expect(SendFailureLine.text(for: try row(i).sendError)
                == "Send failed: The server refused the message")
    }

    // MARK: - The writer, on the path that produces them

    // A send that throws records WHY, where the row can read it. Before this the sender returned false
    // and stored nothing, so the reason existed only inside a notice that clears.
    @Test func aSendThatThrowsRecordsItsReason() async throws {
        struct Refused: LocalizedError { var errorDescription: String? { "Gmail refused the message" } }
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)

        let sent = await InquiryReplySender.sendReply(i, subject: "s", body: "b", now: Date(),
                                                      sender: ThrowingSender(error: Refused()))

        #expect(!sent)
        #expect(i.sendError == "Gmail refused the message")
        #expect(i.sentAt != nil, "an earlier successful send is not unwound by a later failure")
    }

    // And a send that works CLEARS it, or a failure Dan has since recovered from would sit on the row
    // forever, which is the same defect one step on (a guard that fails closed forever).
    @Test func aSendThatSucceedsClearsAnEarlierFailure() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        i.sendError = "an older failure"

        let sent = await InquiryReplySender.sendReply(i, subject: "s", body: "b", now: Date(),
                                                      sender: StubSender())

        #expect(sent)
        #expect(i.sendError == nil)
    }

    // The refusals BEFORE the send is attempted must not invent a reason either, because nothing was
    // tried: an inquiry with no address to answer is a different state from a send that failed (L11).
    @Test func aReplyWithNowhereToSendRecordsNoFailureReason() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        i.inquirerEmail = nil

        let sent = await InquiryReplySender.sendReply(i, subject: "s", body: "b", now: Date(),
                                                      sender: StubSender())

        #expect(!sent)
        #expect(i.sendError == nil)
    }

    // MARK: - Silence when there is nothing wrong

    // The ordinary inquiry, which is every one on the live store today. None of the three may render, or
    // every healthy row grows a warning.
    @Test func aHealthyInquiryRendersNoneOfThem() throws {
        let ctx = ModelContext(try container())
        let r = try row(inquiry(ctx))

        #expect(!r.threadIdDegraded)
        #expect(!r.threadingDegraded)
        #expect(r.sendError == nil)
        #expect(SendFailureLine.text(for: r.sendError) == nil)
    }
}

// A sender that always throws, so the failure path runs with no network and no live mailbox (L2).
private struct ThrowingSender: MailSender {
    let error: any Error
    func send(_ mail: OutgoingMail) async throws -> SentReceipt { throw error }
}

private struct StubSender: MailSender {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        SentReceipt(threadId: "t1", messageID: "<real@mail.gmail.com>")
    }
}
