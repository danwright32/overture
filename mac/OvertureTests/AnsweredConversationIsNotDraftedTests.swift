import Testing
import Foundation
import SwiftData

// #2921: the paid reply-classify run must not draft a conversation Overture has itself recorded as
// answered.
//
// `recipientNeedsClassify` decided from `replied`, `lastReplyText`, `outcomeSource` and whether a reply
// landed after the last draft request, and never read the answered stamp. `startReplyClassifyIfNeeded`
// runs on every window open, so the run picked those conversations up again and spent on them. The draft
// it wrote was then not offered anywhere Dan answers from: `ReplyPanel.isOffered` is gated on
// `hasUnhandledReply`, which is false for exactly these rows.
//
// Measured on the live store on 2026-08-17: a contact wrote at 17:50, Dan answered from his mail client
// at 18:00, detection stamped `replyHandledAt` at 18:06, and a later launch drafted a full reply to that
// message anyway. Two predicates answering "does this conversation still need Dan" differently (L16, L70).
//
// The fix is a shared predicate rather than a second one that happens to agree: the drafter now asks
// `Recipient.hasUnhandledReply`, which is the same property the Answer control is gated on, so the run
// and the surface that would show its draft cannot drift apart.
@MainActor
@Suite("An answered conversation is not drafted")
struct AnsweredConversationIsNotDraftedTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A replied contact on a show, with every reply field the two predicates read set explicitly.
    @discardableResult
    private func contact(_ ctx: ModelContext, key: String,
                         repliedAt: Date?, handledAt: Date?,
                         draftBody: String? = nil, draftRequestedAt: Date? = nil,
                         resolution: RecipientResolution? = nil,
                         bounced: Bool = false) -> Recipient {
        let p = Prospect(naturalKey: key, groupName: "Riverbend Sinfonia", discipline: "music",
                         venue: "Harborlight Hall", performanceDate: "2099-09-01",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "warm",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.outcome = .replied
        ctx.insert(p)
        let r = Recipient(id: key + "@act.example", email: key + "@act.example", provenance: .act)
        r.sendState = .sent
        r.replied = true
        r.lastReplyText = "Thanks, can you send rates?"
        r.repliedAt = repliedAt
        r.replyHandledAt = handledAt
        r.replyDraftBody = draftBody
        r.replyDraftRequestedAt = draftRequestedAt
        r.resolution = resolution
        r.bounced = bounced
        p.addRecipient(r)
        try? ctx.save()
        return r
    }

    private let t = Date(timeIntervalSince1970: 1_000_000)

    // The measured live case: they wrote, Dan answered outside Overture, detection stamped it, and the
    // next launch queued a paid draft for a message already dealt with.
    @Test func doesNotQueueAConversationAnsweredAfterTheyWrote() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx, key: "answered", repliedAt: t, handledAt: t.addingTimeInterval(960))
        #expect(r.hasUnhandledReply == false)
        #expect(ReplyClassifyService.recipientNeedsClassify(r) == false)
        #expect(ReplyClassifyService.buildQueue(from: ctx, generatedAt: "x").items.isEmpty)
    }

    // The re-queue branch, which is the one that survives a draft already existing: a reply newer than the
    // last draft request would re-open this row, and an answer above that reply closes it again. Without
    // the shared predicate this row is queued, drafted and paid for on every window open.
    @Test func doesNotQueueWhenTheFresherReplyWasItselfAnswered() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx, key: "requeued",
                        repliedAt: t.addingTimeInterval(100),   // newer than the draft request below
                        handledAt: t.addingTimeInterval(200),   // and answered after that
                        draftBody: "a draft from the last pass", draftRequestedAt: t)
        #expect(r.hasUnhandledReply == false)
        #expect(ReplyClassifyService.recipientNeedsClassify(r) == false)
        #expect(ReplyClassifyService.buildQueue(from: ctx, generatedAt: "x").items.isEmpty)
    }

    // The positive case, in the same fixture shape, so the two above cannot be passing because a stamped
    // row is refused outright: a conversation Dan answered and they then wrote on AGAIN is still queued.
    @Test func stillQueuesWhenTheyWroteAgainAfterTheAnswer() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx, key: "wroteagain",
                        repliedAt: t.addingTimeInterval(600), handledAt: t.addingTimeInterval(300))
        #expect(r.hasUnhandledReply == true)
        #expect(ReplyClassifyService.recipientNeedsClassify(r) == true)
        #expect(ReplyClassifyService.buildQueue(from: ctx, generatedAt: "x").items.count == 1)
    }

    // A never-answered reply is untouched by this change: it is the whole point of the run.
    @Test func stillQueuesAReplyNobodyHasAnswered() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx, key: "waiting", repliedAt: t, handledAt: nil)
        #expect(r.hasUnhandledReply == true)
        #expect(ReplyClassifyService.recipientNeedsClassify(r) == true)
        #expect(ReplyClassifyService.buildQueue(from: ctx, generatedAt: "x").items.count == 1)
    }

    // #2129's scoped run spends on the one conversation Dan pressed Draft on, so it reads the same
    // predicate and must refuse the same rows. A scope naming an answered conversation yields NOTHING;
    // widening it back to the batch is the failure the scope exists to prevent.
    @Test func aScopedRunOnAnAnsweredConversationQueuesNothing() throws {
        let ctx = ModelContext(try container())
        contact(ctx, key: "answered", repliedAt: t, handledAt: t.addingTimeInterval(960))
        let target = ReplyClassifyService.Target(naturalKey: "answered",
                                                recipientId: "answered@act.example")
        #expect(ReplyClassifyService.buildQueue(from: ctx, generatedAt: "x", only: target).items.isEmpty)
    }

    // The class, not the instance. Over every combination of the facts the two predicates read, the
    // drafter may never queue a conversation the Answer control would refuse to open: a draft nothing can
    // show is spend with no reader. Asserted as the implication rather than as equality, because the
    // drafter legitimately refuses more (no captured words, a hand-marked outcome, a draft already made).
    @Test func neverQueuesAConversationTheAnswerControlWouldNotOffer() throws {
        let ctx = ModelContext(try container())
        var checked = 0
        var refusedForBeingAnswered = 0
        let stamps: [Date?] = [nil, t.addingTimeInterval(-500), t.addingTimeInterval(500)]
        for handled in stamps {
            for resolution in [nil, RecipientResolution.declinedSoft] {
                for bounced in [false, true] {
                    for draft in [nil, "a draft from the last pass"] {
                        let key = "m\(checked)"
                        let r = contact(ctx, key: key, repliedAt: t, handledAt: handled,
                                        draftBody: draft,
                                        draftRequestedAt: t.addingTimeInterval(-1000),
                                        resolution: resolution, bounced: bounced)
                        checked += 1
                        if ReplyClassifyService.recipientNeedsClassify(r) {
                            #expect(r.hasUnhandledReply, Comment(rawValue:
                                "queued a conversation the Answer control would not open: "
                                + "handled=\(String(describing: handled)) "
                                + "resolution=\(String(describing: resolution)) "
                                + "bounced=\(bounced) draft=\(draft != nil)"))
                        } else if !r.hasUnhandledReply {
                            refusedForBeingAnswered += 1
                        }
                    }
                }
            }
        }
        #expect(checked == 24)
        // The matrix really does contain rows the Answer control refuses, so the implication above is not
        // vacuously true of every case it walked (L159).
        #expect(refusedForBeingAnswered > 0)
    }
}
