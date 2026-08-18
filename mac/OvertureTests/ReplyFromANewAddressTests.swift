import Testing
import Foundation
import SwiftData


// #2928: the one Gmail fixture builder, at file scope.
private let replyFromANewAddressGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com")
// #2147, measured on the live store 2026-08-05. Dan emailed two contacts and Nicole replied from an
// address he had never written to: he pitched nbecker@everyvoicechoirs.org, she answered from
// nicolebecker@everyvoicechoirs.org.
//
// On a shared thread the words were filed only against a contact whose address matched the sender, so a
// sender matching nobody left them filed against nobody and discarded. The panel then resolved the reply
// to the row's own contact, showed her colleague's address, and would have sent Dan's answer THERE.
@MainActor
@Suite("A reply from an address nobody was written at")
struct ReplyFromANewAddressTests {
    private let me = "dan@danwrightphotography.com"

    private func b64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Pumpkin Singalong", discipline: "choral", venue: "V",
                         performanceDate: "2026-10-31", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ p: Prospect, _ address: String, group: String? = "g") -> Recipient {
        let r = Recipient(id: address, email: address, provenance: .act)
        r.sendGroupId = group
        r.gmailThreadId = "t"
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.sendState = .sent
        r.gmailMessageId = "msg-\(address)"
        p.addRecipient(r)
        return r
    }

    private func thread(from: String, to: String, body: String) -> Data {
        replyFromANewAddressGmail.thread([
            .init(from: from, to: to, id: "m1", internalDateMillis: 1_754_355_390_000, text: body),
        ])
    }

    // MARK: the words must survive

    // Overture read her message. Filing it against nobody threw away the most valuable thing in the
    // conversation and then told Dan it had not captured what they wrote (L10, L11).
    @Test func anOutsideSendersWordsAreKeptOnTheConversation() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        contact(p, "chelsea@everyvoicechoirs.org")
        contact(p, "nbecker@everyvoicechoirs.org")
        let json = thread(from: "Nicole Becker <nicolebecker@everyvoicechoirs.org>",
                          to: "\(me)", body: "Tuesday works for us.")

        _ = ReplyService.detectReplies(in: [p], selfEmail: me, now: Date(timeIntervalSince1970: 9_999),
                                       fetchThread: { _ in json }, fetchFullThread: { _ in json })
        for r in p.recipients {
            #expect(r.lastReplyText == "Tuesday works for us.", "\(r.id) lost the conversation's words")
            #expect(r.replyFromAddress == "nicolebecker@everyvoicechoirs.org")
        }
    }

    // And the answer is addressed to whoever wrote, which is what makes it reach her at all.
    @Test func theAnswerIsAddressedToTheOutsideSender() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = contact(p, "chelsea@everyvoicechoirs.org")
        contact(p, "nbecker@everyvoicechoirs.org")
        let json = thread(from: "Nicole Becker <nicolebecker@everyvoicechoirs.org>",
                          to: "\(me)", body: "Tuesday works for us.")

        _ = ReplyService.detectReplies(in: [p], selfEmail: me, now: Date(timeIntervalSince1970: 9_999),
                                       fetchThread: { _ in json }, fetchFullThread: { _ in json })
        // The list stands on Chelsea, who never wrote a word of this.
        #expect(SendGroup.isRepresentative(chelsea, in: p))
        let audience = ReplyIdentity.rowAudience(for: chelsea, in: p)
        #expect(audience.lines == ["nicolebecker@everyvoicechoirs.org"])
        #expect(audience.responder == "nicolebecker@everyvoicechoirs.org")
    }

    // When the sender IS one of the contacts, the words still go to them alone, so a shared thread keeps
    // attributing correctly and this fix does not undo #2032.
    @Test func aPeersWordsAreStillFiledUnderThatPeerAlone() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = contact(p, "chelsea@everyvoicechoirs.org")
        let nicole = contact(p, "nbecker@everyvoicechoirs.org")
        let json = thread(from: "Nicole Becker <nbecker@everyvoicechoirs.org>",
                          to: "\(me)", body: "Tuesday works for us.")

        _ = ReplyService.detectReplies(in: [p], selfEmail: me, now: Date(timeIntervalSince1970: 9_999),
                                       fetchThread: { _ in json }, fetchFullThread: { _ in json })
        #expect(nicole.lastReplyText == "Tuesday works for us.")
        #expect(chelsea.lastReplyText == nil, "words must not be filed under a contact who did not write")
    }

    // MARK: the send refuses rather than reaching the wrong person

    // The safety net, and the one that had to hold even before the rest of this: if the person who wrote
    // is not among the people the answer would reach, the send is refused outright. Substituting a nearby
    // contact looks exactly like success and emails somebody else (L75).
    @Test func theSendIsRefusedWhenTheWriterIsNotInTheAudience() {
        #expect(!ReplyPanel.canSend(body: "Tuesday works.", subject: nil,
                                    audience: ["chelsea@everyvoicechoirs.org"],
                                    gmailConnected: true,
                                    writer: "nicolebecker@everyvoicechoirs.org"))
    }

    @Test func theSendIsAllowedWhenTheWriterIsTheOneBeingAnswered() {
        #expect(ReplyPanel.canSend(body: "Tuesday works.", subject: nil,
                                   audience: ["nicolebecker@everyvoicechoirs.org"],
                                   gmailConnected: true,
                                   writer: "nicolebecker@everyvoicechoirs.org"))
    }

    // A reply-all keeps everyone on it, so the writer being one of several is fine.
    @Test func theSendIsAllowedWhenTheWriterIsOneOfSeveral() {
        #expect(ReplyPanel.canSend(body: "Tuesday works.", subject: nil,
                                   audience: ["chelsea@everyvoicechoirs.org", "nicolebecker@everyvoicechoirs.org"],
                                   gmailConnected: true,
                                   writer: "nicolebecker@everyvoicechoirs.org"))
    }

    // Nothing recorded about who wrote is not a reason to refuse: rows that replied before any of this was
    // captured still answer the contact they were sent to, which is the best that is known about them.
    @Test func anUnknownWriterDoesNotBlockTheSend() {
        #expect(ReplyPanel.canSend(body: "Tuesday works.", subject: nil,
                                   audience: ["chelsea@everyvoicechoirs.org"],
                                   gmailConnected: true,
                                   writer: nil))
    }

    // MARK: repairing the conversation already in the store

    // Dan's actual row: replied, writer recorded by the earlier backfill, and no words at all because the
    // sender matched none of the contacts. Detection never revisits a replied row, so without this his
    // panel says "Overture didn't capture what they wrote" forever.
    @Test func anAlreadyRepliedRowGetsItsMissingWordsBack() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = contact(p, "chelsea@everyvoicechoirs.org")
        let nicole = contact(p, "nbecker@everyvoicechoirs.org")
        for r in [chelsea, nicole] {
            r.replied = true
            r.repliedAt = Date(timeIntervalSince1970: 5_000)
            r.replyFromAddress = "nicolebecker@everyvoicechoirs.org"   // the earlier backfill got this far
        }
        let json = thread(from: "Nicole Becker <nicolebecker@everyvoicechoirs.org>",
                          to: "\(me)", body: "Tuesday works for us.")

        let filled = ReplyService.backfillResponders(in: [p], selfEmail: me,
                                            now: Date(timeIntervalSince1970: 9_999),
                                                     fetchThread: { _ in json },
                                                     fetchFullThread: { _ in json })
        #expect(filled == 2)
        for r in p.recipients {
            #expect(r.lastReplyText == "Tuesday works for us.")
            #expect(r.replyAudience?.contains("nicolebecker@everyvoicechoirs.org") == true)
        }
        // And the row now addresses the answer to her rather than her colleague.
        #expect(ReplyIdentity.rowAudience(for: chelsea, in: p).lines == ["nicolebecker@everyvoicechoirs.org"])
    }

    // A row that already holds both is left alone, so the repair cannot become a standing Gmail cost.
    @Test func aCompleteRowIsNotRefetched() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "solo@example.org", group: nil)
        r.replied = true
        r.replyFromAddress = "solo@example.org"
        r.lastReplyText = "Already here."
        var fetches = 0
        let filled = ReplyService.backfillResponders(in: [p], selfEmail: me,
                                            now: Date(timeIntervalSince1970: 9_999),
                                                     fetchThread: { _ in fetches += 1; return nil })
        #expect(filled == 0)
        #expect(fetches == 0)
    }
}
