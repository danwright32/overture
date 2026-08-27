import Testing
import Foundation
import SwiftData

// #2648: `References` is defined as the WHOLE ancestry of a message, oldest first, not its parent.
// `GmailMessage.rfc822` used to write it as the single `inReplyTo` value it was handed, so a third
// message on a conversation named only the second and a client that threads by walking the chain had no
// link back to the first. Overture already sends three message conversations: a pitch, a nudge, then a
// closing note, and `sendFollowUp` re-stamps the contact's stored id with the nudge's.
//
// The visible defect is the same one as #2647 (the message files itself as a separate conversation in
// every standards based client) and would have survived that fix, because #2647 only made the ids real.
@Suite("References carries the whole chain (#2648)")
struct ReferencesChainTests {

    // MARK: the chain builder

    @Test func aReplyChainIsTheParentsChainFollowedByTheParentsId() {
        #expect(MailThreading.references(parentReferences: "<a@x> <b@x>", parentMessageID: "<c@x>")
                == "<a@x> <b@x> <c@x>")
    }

    // The SECOND message of a conversation: its parent is the first, which has no ancestry of its own, so
    // the chain is just the parent's id.
    @Test func theSecondMessageReferencesOnlyTheFirst() {
        #expect(MailThreading.references(parentReferences: nil, parentMessageID: "<first@x>")
                == "<first@x>")
    }

    // Nothing to chain onto is nil, never an empty header. An empty `References:` line is not a shorter
    // chain, it is a malformed one.
    @Test func noAncestryAtAllIsNilRatherThanAnEmptyHeader() {
        #expect(MailThreading.references(parentReferences: nil, parentMessageID: nil) == nil)
        #expect(MailThreading.references(parentReferences: "  ", parentMessageID: "") == nil)
    }

    // A parent whose own id could not be read back (#2647 leaves it nil rather than inventing one) still
    // has an ancestry worth carrying: dropping the chain because one link is missing would strand the
    // whole conversation, not just that generation.
    @Test func aMissingParentIdStillCarriesTheChainItHas() {
        #expect(MailThreading.references(parentReferences: "<a@x> <b@x>", parentMessageID: nil)
                == "<a@x> <b@x>")
    }

    // MARK: the header on the wire

    private func headers(inReplyTo: String?, references: String?) -> String {
        GmailMessage.rfc822(fromName: "Dan", fromEmail: "dan@x.org", to: ["t@y.org"],
                            subject: "Re: Hello", body: "b",
                            inReplyTo: inReplyTo, references: references)
    }

    @Test func referencesNamesEveryAncestorAndInReplyToOnlyTheParent() {
        let raw = headers(inReplyTo: "<c@x>", references: "<a@x> <b@x> <c@x>")
        #expect(raw.contains("References: <a@x> <b@x> <c@x>"))
        #expect(raw.contains("In-Reply-To: <c@x>"))
        #expect(!raw.contains("In-Reply-To: <a@x>"))
    }

    // The floor: a caller that supplies no chain still gets the parent's id as References, which is what
    // this header held before. Dropping it for such a caller would be a regression dressed as a fix.
    @Test func aCallerWithNoChainStillGetsTheParentAsReferences() {
        #expect(headers(inReplyTo: "<c@x>", references: nil).contains("References: <c@x>"))
    }

    // A first send has no ancestry, so neither header appears at all.
    @Test func aFirstSendCarriesNeitherHeader() {
        let raw = headers(inReplyTo: nil, references: nil)
        #expect(!raw.contains("References:"))
        #expect(!raw.contains("In-Reply-To:"))
    }

    // MARK: the composed three message conversation, which is the guard the issue names

    // A pitch, then a nudge, then a closing note, each sent through the real `SendService` paths, with a
    // sender that returns the id Gmail would have assigned. The THIRD message's References has to name
    // both ancestors, in order, oldest first.
    @MainActor
    @Test func theThirdMessageOnAConversationNamesBothAncestorsInOrder() async throws {
        let ctx = ModelContext(try container())
        let p = pitchable(ctx)
        let r = p.recipients.first!
        let sender = ChainSpy()

        let pitchedAt = Date(timeIntervalSince1970: 1_000_000)
        #expect(await SendService.sendOne(p, now: pitchedAt, sender: sender) == true)
        #expect(sender.sent.last?.references == nil)          // a first send has no ancestry

        let nudgedAt = pitchedAt.addingTimeInterval(60 * 60 * 24 * 7)
        #expect(await SendService.sendFollowUp(r, of: p, now: nudgedAt, sender: sender) == true)
        #expect(sender.sent.last?.references == ChainSpy.id(1))   // the pitch alone
        #expect(sender.sent.last?.inReplyTo == ChainSpy.id(1))

        // #2710: the third leg was the closing note until that email was retired. A SECOND follow-up is
        // the third message a contact can now receive, and it is the leg this test actually needs: two
        // ancestors in References is the accumulation being asserted, and one would not show it.
        let nudgedAgainAt = nudgedAt.addingTimeInterval(60 * 60 * 24 * 7)
        #expect(await SendService.sendFollowUp(r, of: p, now: nudgedAgainAt, sender: sender) == true)

        let third = try #require(sender.sent.last)
        #expect(third.references == "\(ChainSpy.id(1)) \(ChainSpy.id(2))")
        #expect(third.inReplyTo == ChainSpy.id(2))            // the immediate parent only
    }

    // L5, carried over from #2647: a send whose own Message-ID could not be read back keeps BOTH the prior
    // id and the prior chain. Advancing one without the other would emit a References that skips a
    // generation, which is the same defect as the one being fixed, only harder to see.
    @MainActor
    @Test func aSendWithNoReadableIdLeavesTheChainWhereItWas() async throws {
        let ctx = ModelContext(try container())
        let p = pitchable(ctx)
        let r = p.recipients.first!
        let good = ChainSpy()

        let pitchedAt = Date(timeIntervalSince1970: 1_000_000)
        #expect(await SendService.sendOne(p, now: pitchedAt, sender: good) == true)
        let nudgedAt = pitchedAt.addingTimeInterval(60 * 60 * 24 * 7)
        #expect(await SendService.sendFollowUp(r, of: p, now: nudgedAt, sender: good) == true)

        let chainAfterTheNudge = r.gmailReferences
        let idAfterTheNudge = r.gmailMessageId
        #expect(chainAfterTheNudge == ChainSpy.id(1))

        r.followUpCount = 0   // let a second nudge through, so the unreadable send is reached
        let againAt = nudgedAt.addingTimeInterval(60 * 60 * 24 * 7)
        #expect(await SendService.sendFollowUp(r, of: p, now: againAt,
                                               sender: UnreadableIdSender()) == true)

        #expect(r.gmailMessageId == idAfterTheNudge)
        #expect(r.gmailReferences == chainAfterTheNudge)
    }

    // MARK: harness

    // Returns a distinct Message-ID per send, the way Gmail assigns its own, and records every mail it was
    // handed so the headers can be read off the composed message rather than off the store.
    private final class ChainSpy: MailSender, @unchecked Sendable {
        static func id(_ n: Int) -> String { "<gmail-\(n)@mail.gmail.com>" }
        var sent: [OutgoingMail] = []
        func send(_ mail: OutgoingMail) async throws -> SentReceipt {
            sent.append(mail)
            return SentReceipt(threadId: "t-chain", messageID: Self.id(sent.count))
        }
    }

    private struct UnreadableIdSender: MailSender {
        func send(_ mail: OutgoingMail) async throws -> SentReceipt {
            SentReceipt(threadId: "t-chain", messageID: nil, messageIDDegraded: true)
        }
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @MainActor
    private func pitchable(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music", venue: "V",
                         performanceDate: "2027-03-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved)
        p.draftSubject = "Photographing your March 1 show"
        p.draftBody = "Hello,\n\nBody"
        ctx.insert(p)
        let r = Recipient(id: "a@b.com", email: "a@b.com", provenance: .manual)
        r.prospect = p
        ctx.insert(r)
        return p
    }
}
