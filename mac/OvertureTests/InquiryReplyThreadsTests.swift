import Testing
import Foundation
import SwiftData

// #2661: an inquiry reply threaded onto nothing. `InquiryReplySender.sendReply` built its mail with no
// `inReplyTo`, no `references` and no `threadId`, so Dan's answer to somebody who emailed him arrived in
// their inbox as a brand new conversation, in every client including Gmail: no `threadId` on the send
// means Gmail does not thread it server side either.
//
// #1513 made this path send ANY reply Dan writes, not only the first, so a second answer on one inquiry
// started a third unrelated conversation.
//
// IT MATTERS BEYOND TIDINESS. Reply detection watches `gmailThreadId`. An answer sent off-thread means
// the inquirer's next message lands on the NEW thread Gmail just created, which is not the one being
// watched, so a reply to Dan's own answer can go unnoticed entirely.
//
// Threaded through exactly the pieces the prospect reply path uses (`SendService.sendReplyDraft`), not a
// second implementation of the same idea: `inReplyTo` from the stored message id, `references` through
// `MailThreading.references`, and `threadId` from the stored thread.
@MainActor
@Suite("An inquiry reply threads onto its own conversation (#2661)")
struct InquiryReplyThreadsTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // An inquiry Dan has already answered once, so it carries the conversation a second answer has to
    // land on. That is the state #1513 created and the one the defect is worst in.
    private func answered(_ ctx: ModelContext) -> Inquiry {
        let i = Inquiry(source: .directEmail, inquirerName: "Nora Vance",
                        inquirerEmail: "nora@example.com", eventName: "A recital")
        i.gmailThreadId = "thread-1"
        i.gmailMessageId = "<theirs@mail.gmail.com>"
        ctx.insert(i)
        return i
    }

    // MARK: - The three headers

    @Test func aReplyNamesTheConversationItIsAnsweringOnAllThreeCounts() async throws {
        let ctx = ModelContext(try container())
        let i = answered(ctx)
        let sender = CapturingSender()

        #expect(await InquiryReplySender.sendReply(i, subject: "Re: your inquiry", body: "b",
                                                   now: Date(), sender: sender))

        let mail = try #require(sender.sent)
        #expect(mail.inReplyTo == "<theirs@mail.gmail.com>")
        #expect(mail.threadId == "thread-1")
        #expect(mail.references == "<theirs@mail.gmail.com>")
    }

    // #2648's rule applied here: the second answer's ancestry names BOTH ancestors, not only its parent,
    // because a chain that skips a generation is what makes a long thread split in a client that reads
    // References rather than Gmail's own threadId.
    @Test func aSecondReplyNamesBothAncestors() async throws {
        let ctx = ModelContext(try container())
        let i = answered(ctx)
        let first = CapturingSender(messageID: "<ours-1@mail.gmail.com>")

        _ = await InquiryReplySender.sendReply(i, subject: "s", body: "b", now: Date(), sender: first)

        let second = CapturingSender(messageID: "<ours-2@mail.gmail.com>")
        _ = await InquiryReplySender.sendReply(i, subject: "s", body: "b2", now: Date(), sender: second)

        let mail = try #require(second.sent)
        #expect(mail.inReplyTo == "<ours-1@mail.gmail.com>")
        #expect(mail.references == "<theirs@mail.gmail.com> <ours-1@mail.gmail.com>")
    }

    // MARK: - What the send stores back

    // The chain moves WITH the message it is the ancestry of, and only when there is a message to move it
    // to. Assigning either unconditionally would blank a good id the moment a read back failed, leaving
    // the next message on this conversation with nothing to reference at all (L5).
    @Test func theChainIsStoredBesideTheMessageItBelongsTo() async throws {
        let ctx = ModelContext(try container())
        let i = answered(ctx)

        _ = await InquiryReplySender.sendReply(i, subject: "s", body: "b", now: Date(),
                                               sender: CapturingSender(messageID: "<ours-1@mail.gmail.com>"))

        #expect(i.gmailMessageId == "<ours-1@mail.gmail.com>")
        #expect(i.gmailReferences == "<theirs@mail.gmail.com>")
    }

    @Test func aReadBackThatFailedKeepsThePriorIdAndItsChain() async throws {
        let ctx = ModelContext(try container())
        let i = answered(ctx)
        i.gmailReferences = "<older@mail.gmail.com>"

        _ = await InquiryReplySender.sendReply(i, subject: "s", body: "b", now: Date(),
                                               sender: CapturingSender(messageID: nil,
                                                                       messageIDDegraded: true))

        #expect(i.gmailMessageId == "<theirs@mail.gmail.com>", "a real ancestor still threads; nothing does not")
        #expect(i.gmailReferences == "<older@mail.gmail.com>")
        #expect(i.threadingDegraded)
    }

    // MARK: - The first answer, which has no conversation yet

    // An inquiry Dan logged by hand carries no thread and no message id, because nobody has emailed
    // through Gmail about it. The send must not invent headers naming a conversation that does not
    // exist: an empty `References` is honest, a fabricated one points at nothing.
    @Test func anInquiryWithNoConversationYetSendsNoThreadingHeaders() async throws {
        let ctx = ModelContext(try container())
        let i = Inquiry(source: .contactForm, inquirerName: "Nora Vance",
                        inquirerEmail: "nora@example.com", eventName: "A recital")
        ctx.insert(i)
        let sender = CapturingSender()

        #expect(await InquiryReplySender.sendReply(i, subject: "s", body: "b", now: Date(), sender: sender))

        let mail = try #require(sender.sent)
        #expect(mail.inReplyTo == nil)
        #expect(mail.references == nil)
        #expect(mail.threadId == nil)
    }
}

// Captures the mail it was handed, so the headers can be asserted with no network and no live mailbox.
private final class CapturingSender: MailSender, @unchecked Sendable {
    var sent: OutgoingMail?
    let messageID: String?
    let messageIDDegraded: Bool

    init(messageID: String? = "<ours@mail.gmail.com>", messageIDDegraded: Bool = false) {
        self.messageID = messageID
        self.messageIDDegraded = messageIDDegraded
    }

    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        sent = mail
        return SentReceipt(threadId: "thread-1", messageID: messageID,
                           messageIDDegraded: messageIDDegraded)
    }
}
