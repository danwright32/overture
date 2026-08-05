import Testing
import Foundation
import SwiftData

// #2129: "Draft with AI" must draft the ONE reply it was pressed on.
//
// The drafter run collects every reply awaiting a draft and works through them in a single detached,
// paid pass, cancellable only run-wide. That is right for the batch it was built for and wrong for a
// button on one reply: pressing it would spend across every waiting conversation, and Cancel would
// abandon all of them. Dan's rule, 2026-08-05: "buttons need to do what they say."
@MainActor
@Suite("The AI drafter can be scoped to one reply")
struct ScopedReplyDraftTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func repliedShow(_ ctx: ModelContext, key: String, address: String,
                             words: String = "Sounds good, tell me more.") -> Recipient {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "choral", venue: "V",
                         performanceDate: "2026-10-31", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        let r = Recipient(id: address, email: address, provenance: .act)
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.sendState = .sent
        r.gmailMessageId = "msg-\(address)"
        r.replied = true
        r.lastReplyText = words
        p.addRecipient(r)
        return r
    }

    // The batch the run was built for: unscoped, it takes everything waiting.
    @Test func theUnscopedQueueTakesEveryReplyWaiting() throws {
        let ctx = ModelContext(try container())
        repliedShow(ctx, key: "A", address: "a@x.org")
        repliedShow(ctx, key: "B", address: "b@x.org")
        let queue = ReplyClassifyService.buildQueue(from: ctx, generatedAt: "t")
        #expect(queue.items.count == 2)
    }

    // Scoped, it takes exactly the one asked for and spends on nothing else.
    @Test func aScopedQueueTakesOnlyTheReplyAskedFor() throws {
        let ctx = ModelContext(try container())
        repliedShow(ctx, key: "A", address: "a@x.org")
        repliedShow(ctx, key: "B", address: "b@x.org")
        let queue = ReplyClassifyService.buildQueue(
            from: ctx, generatedAt: "t",
            only: ReplyClassifyService.Target(naturalKey: "B", recipientId: "b@x.org"))
        #expect(queue.items.count == 1)
        #expect(queue.items.first?.naturalKey == "B")
        #expect(queue.items.first?.recipientId == "b@x.org")
    }

    // The property that matters most: a scoped request that matches nothing yields NOTHING. Falling back
    // to the whole batch would spend Dan's money across every waiting conversation from a button he
    // pressed on one, which is the failure this scoping exists to prevent.
    @Test func aScopedRequestThatMatchesNothingDraftsNothing() throws {
        let ctx = ModelContext(try container())
        repliedShow(ctx, key: "A", address: "a@x.org")
        repliedShow(ctx, key: "B", address: "b@x.org")
        let queue = ReplyClassifyService.buildQueue(
            from: ctx, generatedAt: "t",
            only: ReplyClassifyService.Target(naturalKey: "A", recipientId: "nobody@x.org"))
        #expect(queue.items.isEmpty)
    }

    // A scope naming a contact who does not need a draft is also nothing, rather than quietly widening.
    @Test func aScopedRequestOnAContactNeedingNoDraftDraftsNothing() throws {
        let ctx = ModelContext(try container())
        repliedShow(ctx, key: "A", address: "a@x.org")
        let b = repliedShow(ctx, key: "B", address: "b@x.org")
        b.replyDraftBody = "already drafted"      // no longer awaiting one
        let queue = ReplyClassifyService.buildQueue(
            from: ctx, generatedAt: "t",
            only: ReplyClassifyService.Target(naturalKey: "B", recipientId: "b@x.org"))
        #expect(queue.items.isEmpty)
    }

    // The scope matches the show as well as the contact, so two shows sharing a contact address cannot
    // draft each other's conversation.
    @Test func theScopeMatchesTheShowNotJustTheAddress() throws {
        let ctx = ModelContext(try container())
        repliedShow(ctx, key: "A", address: "shared@x.org", words: "A's words")
        repliedShow(ctx, key: "B", address: "shared@x.org", words: "B's words")
        let queue = ReplyClassifyService.buildQueue(
            from: ctx, generatedAt: "t",
            only: ReplyClassifyService.Target(naturalKey: "B", recipientId: "shared@x.org"))
        #expect(queue.items.count == 1)
        #expect(queue.items.first?.replyText == "B's words")
    }
}
