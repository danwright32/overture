import Testing
import Foundation
import SwiftData

// #2910, Dan's call on 2026-08-17 reading back what #2900 had shipped: an unanswered reply keeps
// nagging until it is ANSWERED, whatever ending the show carries.
//
// Closing a show out records what happened to the SHOW. It does not mean Dan wrote back to the person
// who took the trouble to reply, so it must not silence them. #2900 had made an ending close the reply
// everywhere at once, which was right about one thing (a closed out show should stop being work) and
// wrong about the person still waiting.
//
// What makes that safe is that clearing a reply no longer needs an ending to stand in for it. Four acts
// retire one now, and #2899 added the one Dan actually performs when he is away from his desk:
//
//   - answering through Overture (`AnsweredReply.record`)
//   - answering from his mail client, which detection reads back (`AnsweredElsewhere`, #2865)
//   - ticking the triage task off in OmniFocus (#2899)
//   - standing the contact or show down (`ProspectMutations.standDown`)
@Suite("A reply on a closed out show")
struct AReplyOnAClosedOutShowTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, key: String = "an evening of song|2026-09-04|the corner room") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Corner Room Collective", discipline: "choral",
                         venue: "the corner room", performanceDate: "2026-09-04", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func repliedContact(_ ctx: ModelContext, on p: Prospect, now: Date) -> Recipient {
        let r = Recipient(id: "booking@example.invalid", email: "booking@example.invalid", provenance: .act)
        r.sentAt = now.addingTimeInterval(-86_400 * 5)
        r.sendState = .sent
        r.gmailMessageId = "msg-1"
        r.replied = true
        r.lastReplyId = "reply-1"
        r.inboundReplySentAt = now.addingTimeInterval(-3_600)
        r.prospect = p
        p.recipients.append(r)
        return r
    }

    // Exhaustive over the vocabulary rather than a sample, so an ending added later is judged by this
    // rule rather than by whoever remembers it.
    @Test func noEndingDanCanRecordSilencesAnUnansweredReply() throws {
        for ending in ShowOutcome.danCanChoose where ending != .booked {
            let ctx = ModelContext(try container())
            let now = Date(timeIntervalSince1970: 1_780_000_000)
            let p = show(ctx)
            let r = repliedContact(ctx, on: p, now: now)
            p.showOutcome = ending

            #expect(r.hasUnhandledReply, "\(ending.rawValue) must not answer the person for him")
            #expect(p.hasUnhandledReply, "\(ending.rawValue) must not answer the person for him")
        }
    }

    // The live shape of #2900, now deliberately the other way round: the triage task keeps coming, and
    // ticking it off in OmniFocus (#2899) is what retires it.
    @Test func aClosedOutShowStillMintsATriageTaskUntilTheReplyIsAnswered() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let p = show(ctx)
        let r = repliedContact(ctx, on: p, now: now)
        p.showOutcome = .theySaidNo

        let desired = OmniFocusSync.desired(from: [p], now: now, horizonDays: 14)
        #expect(desired.count == 1)
        #expect(desired.first?.kind == .replyTriage)

        // Answering it is what stops it, wherever the answer happened.
        AnsweredReply.recordHandled(on: r, in: p, now: now)
        #expect(!r.hasUnhandledReply)
        #expect(OmniFocusSync.desired(from: [p], now: now, horizonDays: 14).isEmpty)
    }

    // A reply that arrives AFTER the ending is the case that most needs to be heard: "they said no,
    // then wrote back a month later to say the date freed up" (this was #2908, which this closes).
    @Test func aReplyArrivingAfterTheEndingIsStillHeard() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let p = show(ctx)
        let r = repliedContact(ctx, on: p, now: now)
        p.showOutcome = .neverHeardBack
        AnsweredReply.recordHandled(on: r, in: p, now: now)
        #expect(!r.hasUnhandledReply)

        // A month later they write again on the same thread.
        let later = now.addingTimeInterval(86_400 * 30)
        r.inboundReplySentAt = later
        r.lastReplyId = "reply-2"

        #expect(r.hasUnhandledReply)
        #expect(OmniFocusSync.desired(from: [p], now: later, horizonDays: 14).count == 1)
    }

    // A booked show is the one long-standing exclusion, and it lives where it always has, on the
    // prospect-level rollup. It is not an ending Dan recorded ABOUT the conversation, it is the
    // conversation having succeeded.
    //
    // Exercised through the SHOW's own booking rather than through the replying contact's resolution: a
    // contact carrying `resolution == .booked` is already not asking, so a test written that way passes
    // whether this exclusion exists or not, and the mutation that deletes it survives (L1).
    @Test func aBookedShowStillRollsUpAsNothingOutstanding() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let p = show(ctx)
        let r = repliedContact(ctx, on: p, now: now)
        p.markOutcomeManually(.booked, now: now)

        #expect(p.isBooked)
        #expect(r.hasUnhandledReply, "the contact itself is still owed an answer")
        #expect(!p.hasUnhandledReply, "but the show has nothing outstanding: it booked")
    }

    // A contact with no show wired at all (every bare-Recipient unit test) is unaffected.
    @Test func aContactWithNoShowIsUnaffected() {
        let r = Recipient(id: "a@example.invalid", email: "a@example.invalid", provenance: .act)
        r.replied = true
        #expect(r.hasUnhandledReply)
    }
}
