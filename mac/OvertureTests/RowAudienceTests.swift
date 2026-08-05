import Testing
import Foundation
import SwiftData

// #2121, Dan (2026-08-05): "I think I want who my reply will reach. If I email 5 and one responds with a
// single other person on cc, even if it's not one of the 5, I should see the emails of the 2 I'm about to
// email with the one that actually responded highlighted."
//
// So the row lists the audience of the email it is ABOUT to send, not the people it once sent to. Which
// audience that is depends on what the row's next email is, and both are already decided by the send
// paths rather than invented here:
//
//   an unhandled reply  -> SendService.sendReply addresses SendGroup.replyAudience
//   anything else       -> sendFollowUp / sendConversationNudge address the whole send group
//
// Reading the audience from the same place the send does is the point (L64): what Dan reviews on the row
// has to be who it actually goes to, and a roster drawn from the original send would say "2 people" for a
// reply that reaches one.
@MainActor
@Suite("The row lists who its next email reaches")
struct RowAudienceTests {
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
        r.gmailThreadId = "t"
        r.sendGroupId = group
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.sendState = .sent
        r.gmailMessageId = "msg-\(address)"
        p.addRecipient(r)
        return r
    }

    // Dan's exact scenario, scaled down to the shape his store actually holds. Two were emailed, one wrote
    // back and brought somebody new onto the thread, so the answer reaches those two and NOT the original
    // second contact.
    @Test func aReplyListsWhoTheAnswerReachesIncludingSomebodyNeverEmailed() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = contact(p, "chelsea@everyvoicechoirs.org")
        let nicole = contact(p, "nbecker@everyvoicechoirs.org")
        for r in [chelsea, nicole] {
            r.replied = true
            r.replyFromAddress = "nbecker@everyvoicechoirs.org"
        }
        nicole.replyAudience = ["nbecker@everyvoicechoirs.org", "ray@elsewhere.example"]
        chelsea.replyAudience = nicole.replyAudience

        let audience = ReplyIdentity.rowAudience(for: chelsea, in: p)
        #expect(audience.lines == ["nbecker@everyvoicechoirs.org", "ray@elsewhere.example"])
        #expect(audience.responder == "nbecker@everyvoicechoirs.org")
    }

    // A private reply. The answer goes back to the one person who wrote, so the row says one person, even
    // though the pitch went to two. Saying "2" here would promise an audience the send will not use.
    @Test func aPrivateReplyListsOnlyTheWriter() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = contact(p, "chelsea@everyvoicechoirs.org")
        let nicole = contact(p, "nbecker@everyvoicechoirs.org")
        for r in [chelsea, nicole] {
            r.replied = true
            r.replyFromAddress = "nbecker@everyvoicechoirs.org"
            r.replyAudience = ["nbecker@everyvoicechoirs.org"]
        }
        let audience = ReplyIdentity.rowAudience(for: chelsea, in: p)
        #expect(audience.lines == ["nbecker@everyvoicechoirs.org"])
        #expect(audience.responder == "nbecker@everyvoicechoirs.org")
    }

    // Nobody has written back, so the next email is a follow-up, and a follow-up is addressed to everyone
    // on the thread. Nobody is highlighted, because nobody has said anything.
    @Test func anUnrepliedRowListsEveryoneTheFollowUpReaches() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = contact(p, "chelsea@everyvoicechoirs.org")
        contact(p, "nbecker@everyvoicechoirs.org")
        let audience = ReplyIdentity.rowAudience(for: chelsea, in: p)
        #expect(audience.lines == ["chelsea@everyvoicechoirs.org", "nbecker@everyvoicechoirs.org"])
        #expect(audience.responder == nil)
    }

    // The ordinary case, which is nearly every row in the store: one person, listed once, nothing marked.
    @Test func aSoloRowListsThatOnePerson() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let solo = contact(p, "solo@example.org", group: nil)
        let audience = ReplyIdentity.rowAudience(for: solo, in: p)
        #expect(audience.lines == ["solo@example.org"])
        #expect(audience.responder == nil)
    }

    // Measured on the live store 2026-08-05: the only real multi-person send (Nicole and Chelsea) carries
    // NO stored reply audience, because their reply predates the capture. The reply path falls back to the
    // writer alone there, so the row has to say the same thing rather than listing both and overstating it.
    @Test func aRepliedRowWithNoCapturedAudienceListsTheWriterAlone() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = contact(p, "chelsea@everyvoicechoirs.org")
        let nicole = contact(p, "nbecker@everyvoicechoirs.org")
        for r in [chelsea, nicole] {
            r.replied = true
            r.replyFromAddress = "nbecker@everyvoicechoirs.org"
        }
        // Standing on Chelsea's row, whose own address is the fallback the reply path would use for HER.
        let audience = ReplyIdentity.rowAudience(for: nicole, in: p)
        #expect(audience.lines == ["nbecker@everyvoicechoirs.org"])
        #expect(audience.responder == "nbecker@everyvoicechoirs.org")
    }

    // A row that cannot be emailed at all (a form outreach) still has to say something, and must never
    // render as an empty gap where a contact should be.
    @Test func aRowWithNoAddressStillNamesSomething() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = Recipient(id: "formonly", email: nil, provenance: .act)
        r.sendGroupId = nil
        p.addRecipient(r)
        let audience = ReplyIdentity.rowAudience(for: r, in: p)
        #expect(audience.lines == ["no contact"])
        #expect(audience.responder == nil)
    }

    // The highlight marks somebody who is actually on the list. A writer absent from the audience would
    // otherwise be styled onto nothing, which reads as no highlight at all rather than as a fault.
    @Test func nobodyIsHighlightedWhenTheWriterIsNotInTheAudience() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "chelsea@everyvoicechoirs.org", group: nil)
        r.replied = true
        r.replyFromAddress = "ray@elsewhere.example"
        r.replyAudience = ["chelsea@everyvoicechoirs.org"]
        let audience = ReplyIdentity.rowAudience(for: r, in: p)
        #expect(audience.lines == ["chelsea@everyvoicechoirs.org"])
        #expect(audience.responder == nil)
    }

    // The highlight is weight and colour, and a screen reader can perceive neither, so for the one line
    // carrying it the mark has to be in the WORDS. Every other line reads as just its address, with no
    // decoration to sit through.
    @Test func theWriterIsMarkedInWordsForAScreenReader() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = contact(p, "chelsea@everyvoicechoirs.org")
        let nicole = contact(p, "nbecker@everyvoicechoirs.org")
        for r in [chelsea, nicole] {
            r.replied = true
            r.replyFromAddress = "nbecker@everyvoicechoirs.org"
            r.replyAudience = ["nbecker@everyvoicechoirs.org", "chelsea@everyvoicechoirs.org"]
        }
        let audience = ReplyIdentity.rowAudience(for: chelsea, in: p)
        #expect(audience.spokenLabel(for: "nbecker@everyvoicechoirs.org") == "nbecker@everyvoicechoirs.org, replied")
        #expect(audience.spokenLabel(for: "chelsea@everyvoicechoirs.org") == "chelsea@everyvoicechoirs.org")
    }

    // Address comparison is the same one reply detection uses, so casing and a display name cannot make
    // the writer fail to match their own line and lose the highlight.
    @Test func theHighlightMatchesRegardlessOfCasing() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "chelsea@everyvoicechoirs.org", group: nil)
        r.replied = true
        r.replyFromAddress = "Chelsea@EveryVoiceChoirs.org"
        r.replyAudience = ["chelsea@everyvoicechoirs.org"]
        #expect(ReplyIdentity.rowAudience(for: r, in: p).responder == "chelsea@everyvoicechoirs.org")
    }
}
