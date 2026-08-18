import Testing
import Foundation
import SwiftData

private final class CapturingSender: MailSender, @unchecked Sendable {
    var last: OutgoingMail?
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        last = mail
        return SentReceipt(threadId: "t", messageID: "<m>")
    }
}

// #2063: Dan's answer goes to the people the reply he is answering went to, not to everyone the ORIGINAL
// email went to.
//
// The send group is a record of what Overture did. Only the incoming reply records what the other side
// chose, and the two differ the moment somebody replies privately or drops a name. Dan's rule, 2026-08-04:
// "it should mimic them. if they reply all, i should reply all. if they respond directly to me I should
// reply directly to them. if they respond and remove 2 of the other 4 people and only include 3 of the
// original 5, I should do the same."
@MainActor
@Suite("A reply is addressed the way the reply it answers was addressed")
struct ReplyMirrorsItsAudienceTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A show emailed to three contacts as ONE message, so all three share a send group.
    private func jointlyEmailed(_ ctx: ModelContext) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Lumen", performanceDate: "2026-07-01", venue: "V")
        let p = Prospect(naturalKey: key, groupName: "Lumen", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved, ingestedAt: Date(timeIntervalSince1970: 1))
        p.draftSubject = "S"; p.draftBody = "body"
        ctx.insert(p)
        let people = [("ann@org.example", "Ann"), ("ben@org.example", "Ben"), ("cara@org.example", "Cara")]
        let recipients = people.map { email, name in
            let r = Recipient(id: email, email: email, name: name, provenance: .presenter)
            r.sendGroupId = "g1"          // they all received the same email
            r.sendState = .sent
            return r
        }
        p.setRecipients(recipients)
        try? ctx.save()
        return p
    }

    // The contact who wrote back, holding a drafted answer ready to send.
    private func replier(_ p: Prospect, audience: [String]?) -> Recipient {
        let r = p.recipients.first { $0.email == "ann@org.example" }!
        r.gmailThreadId = "rt"; r.gmailMessageId = "<rm>"; r.replied = true
        r.replyDraftSubject = "Re: Photographing you"
        r.replyDraftBody = "July works."
        r.replyAudience = audience
        return r
    }

    @Test func aPrivateReplyIsAnsweredPrivately() async throws {
        let ctx = ModelContext(try container())
        let p = jointlyEmailed(ctx)
        // Ann wrote to Dan alone, deliberately not to Ben and Cara.
        let r = replier(p, audience: ["ann@org.example"])
        let sender = CapturingSender()

        #expect(await SendService.sendReplyDraft(r, of: p, now: Date(timeIntervalSince1970: 10),
                                                 sender: sender) == true)

        #expect(sender.last?.to == ["ann@org.example"])
    }

    @Test func aReplyAllIsAnsweredToEveryoneOnIt() async throws {
        let ctx = ModelContext(try container())
        let p = jointlyEmailed(ctx)
        let r = replier(p, audience: ["ann@org.example", "ben@org.example", "cara@org.example"])
        let sender = CapturingSender()

        #expect(await SendService.sendReplyDraft(r, of: p, now: Date(timeIntervalSince1970: 10),
                                                 sender: sender) == true)

        #expect(sender.last?.to == ["ann@org.example", "ben@org.example", "cara@org.example"])
    }

    // Dan's worked example, scaled to three: the reply keeps two of them, so his answer keeps two.
    @Test func aReplyThatDroppedSomeoneIsAnsweredWithoutThem() async throws {
        let ctx = ModelContext(try container())
        let p = jointlyEmailed(ctx)
        let r = replier(p, audience: ["ann@org.example", "ben@org.example"])
        let sender = CapturingSender()

        #expect(await SendService.sendReplyDraft(r, of: p, now: Date(timeIntervalSince1970: 10),
                                                 sender: sender) == true)

        #expect(sender.last?.to == ["ann@org.example", "ben@org.example"])
        #expect(sender.last?.to.contains("cara@org.example") == false)
    }

    // Somebody the writer brought in is on the conversation, and Overture has no contact row for them.
    // Mirroring means they hear the answer, which is what pressing reply-all does in any mail client.
    @Test func someoneTheWriterAddedHearsTheAnswerEvenWithNoContactRow() async throws {
        let ctx = ModelContext(try container())
        let p = jointlyEmailed(ctx)
        let r = replier(p, audience: ["ann@org.example", "colleague@elsewhere.example"])
        let sender = CapturingSender()

        #expect(await SendService.sendReplyDraft(r, of: p, now: Date(timeIntervalSince1970: 10),
                                                 sender: sender) == true)

        #expect(sender.last?.to == ["ann@org.example", "colleague@elsewhere.example"])
    }

    // The one that matters most. Every reply captured before this shipped has no audience recorded, and the
    // safe reading of "I do not know who saw it" is the narrowest one. Answering the whole group on a guess
    // is the exact failure this exists to prevent, and Dan can always add somebody back.
    @Test func aReplyWithNoCapturedAudienceIsAnsweredToTheWriterAloneNotTheGroup() async throws {
        let ctx = ModelContext(try container())
        let p = jointlyEmailed(ctx)
        let r = replier(p, audience: nil)
        let sender = CapturingSender()

        #expect(await SendService.sendReplyDraft(r, of: p, now: Date(timeIntervalSince1970: 10),
                                                 sender: sender) == true)

        #expect(sender.last?.to == ["ann@org.example"])
    }

    // An audience that somehow arrived empty is the same "cannot mirror this" case as never captured, and
    // must not become a send to nobody or a send to everybody.
    @Test func anEmptyCapturedAudienceFallsBackToTheWriterAlone() async throws {
        let ctx = ModelContext(try container())
        let p = jointlyEmailed(ctx)
        let r = replier(p, audience: [])
        let sender = CapturingSender()

        #expect(await SendService.sendReplyDraft(r, of: p, now: Date(timeIntervalSince1970: 10),
                                                 sender: sender) == true)

        #expect(sender.last?.to == ["ann@org.example"])
    }

    // MARK: - Capturing it when the reply lands

    // None of the above means anything unless the audience is actually recorded off the incoming message.
    // The headers are already downloaded: the reply checker full-fetches any thread carrying a reply in
    // order to get the body, and a full fetch carries To and Cc.
    @Test func detectingAReplyRecordsWhoItWasAddressedTo() throws {
        let me = "dan@danwrightphotography.com"
        let ctx = ModelContext(try container())
        let p = jointlyEmailed(ctx)
        let ann = p.recipients.first { $0.email == "ann@org.example" }!
        ann.gmailThreadId = "t1"
        p.sentAt = Date(timeIntervalSince1970: 1)

        // Ann replied to Dan and to Ben, leaving Cara off.
        let full = GmailFixture(selfEmail: me).thread([
            .init(from: me, to: "ann@org.example, ben@org.example, cara@org.example",
                  internalDateMillis: 1000),
            .init(from: "Ann <ann@org.example>", to: "\(me), ben@org.example",
                  internalDateMillis: 2000, text: "July works."),
        ])

        let n = ReplyService.detectReplies(in: [p], selfEmail: me, now: Date(timeIntervalSince1970: 10),
                                           fetchThread: { _ in full }, fetchFullThread: { _ in full })

        #expect(n == 1)
        #expect(ann.replyAudience == ["ann@org.example", "ben@org.example"])
    }

    // MARK: - The same rule on the inquiry path

    // An inquiry is its own single thread, so it has no group to over-send to and the failure here is the
    // mirror image: somebody the inquirer CC'd (a partner, a colleague booking alongside them) is dropped
    // from Dan's answer even though they wrote in together. Same rule, same fallback, so the two reply
    // paths cannot answer "who does this reach" differently (L30).
    @Test func anInquiryReplyReachesEveryoneTheInquiryReplyNamed() async throws {
        let inq = Inquiry(source: .contactForm, inquirerName: "Ann", inquirerEmail: "ann@org.example",
                          eventName: "Gala", performanceDate: "2026-09-01", venue: "V")
        inq.replyAudience = ["ann@org.example", "partner@org.example"]
        let sender = CapturingSender()

        #expect(await InquiryReplySender.sendReply(inq, subject: "Re: your enquiry", body: "Yes.",
                                                   now: Date(timeIntervalSince1970: 10),
                                                   sender: sender) == true)

        #expect(sender.last?.to == ["ann@org.example", "partner@org.example"])
    }

    @Test func anInquiryWithNoCapturedAudienceStillReachesTheInquirer() async throws {
        let inq = Inquiry(source: .contactForm, inquirerName: "Ann", inquirerEmail: "ann@org.example",
                          eventName: "Gala", performanceDate: "2026-09-01", venue: "V")
        let sender = CapturingSender()

        #expect(await InquiryReplySender.sendReply(inq, subject: "Re: your enquiry", body: "Yes.",
                                                   now: Date(timeIntervalSince1970: 10),
                                                   sender: sender) == true)

        #expect(sender.last?.to == ["ann@org.example"])
    }

}
