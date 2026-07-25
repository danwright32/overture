import Testing
import Foundation
@testable import Overture

// Phase 2 (#1435): Dan types and sends the first reply to an inquiry himself, through a NEW
// standalone sender (never SendService, which is Prospect-only, AI-drafted, and drip-managed). Built
// on the same MailSender primitive so reply detection can attach to the resulting thread.
@MainActor
@Suite("Inquiry first-reply send")
struct InquiryReplySenderTests {
    private struct StubSender: MailSender {
        let receipt: SentReceipt
        func send(_ mail: OutgoingMail) async throws -> SentReceipt { receipt }
    }
    private struct FailingSender: MailSender {
        func send(_ mail: OutgoingMail) async throws -> SentReceipt { throw MailSenderError.notConfigured }
    }

    private func inquiry(email: String? = "ada@x.org") -> Inquiry {
        Inquiry(source: .directEmail, inquirerName: "Ada", inquirerEmail: email, eventName: "Gala")
    }

    @Test func aSuccessfulSendStampsThreadAndSentAt() async {
        let inq = inquiry()
        let sender = StubSender(receipt: SentReceipt(threadId: "th-1", messageID: "mid-1"))
        let ok = await InquiryReplySender.sendFirstReply(inq, subject: "Re: your inquiry", body: "Hi Ada",
                                                         now: Date(timeIntervalSince1970: 5), sender: sender)
        #expect(ok == true)
        #expect(inq.sentAt == Date(timeIntervalSince1970: 5))
        #expect(inq.gmailThreadId == "th-1")
        #expect(inq.gmailMessageId == "mid-1")
        #expect(inq.wasProvablyContacted == true)
    }

    // Failure path: a refused send leaves the inquiry unsent and reports the failure to the caller,
    // never a silent fake success.
    @Test func aFailedSendLeavesTheInquiryUnsentAndReportsFailure() async {
        let inq = inquiry()
        let ok = await InquiryReplySender.sendFirstReply(inq, subject: "s", body: "b",
                                                         now: Date(), sender: FailingSender())
        #expect(ok == false)
        #expect(inq.sentAt == nil)
        #expect(inq.gmailThreadId == nil)
        #expect(inq.wasProvablyContacted == false)
    }

    @Test func aMissingRecipientEmailIsNotSent() async {
        let inq = inquiry(email: nil)
        let ok = await InquiryReplySender.sendFirstReply(inq, subject: "s", body: "b",
                                                         now: Date(), sender: StubSender(receipt: SentReceipt(threadId: "x")))
        #expect(ok == false)
        #expect(inq.sentAt == nil)
    }

    // A send that succeeds but whose thread id couldn't be parsed (#483) still records the send and
    // flags the degradation, rather than losing the send or guessing a thread id.
    @Test func aDegradedThreadIsRecordedAndFlagged() async {
        let inq = inquiry()
        let sender = StubSender(receipt: SentReceipt(threadId: "", messageID: "mid-2", threadIdDegraded: true))
        let ok = await InquiryReplySender.sendFirstReply(inq, subject: "s", body: "b",
                                                         now: Date(timeIntervalSince1970: 9), sender: sender)
        #expect(ok == true)
        #expect(inq.sentAt == Date(timeIntervalSince1970: 9))
        #expect(inq.threadIdDegraded == true)
    }
}
