import Testing
import Foundation
import SwiftData

// #2190. Dan answered Nicole Becker's reply at 18:49:38 on 2026-08-05. #2170, which added the stamp that
// retires the Answer button, merged at 21:38:57 the same day, two hours fifty minutes later. His answer was
// recorded (the frozen sent body and the send time are both on the row) but the field that means "Dan
// answered" did not exist yet, so nothing wrote it and the row went on asking for work he had done.
//
// A new field whose EMPTY value carries meaning makes every row that already exists assert that meaning.
// The evidence sat on the same row the whole time, in a different column.
//
// Keyed on the defect's SIGNATURE (an answer demonstrably sent, later than the reply arrived) rather than
// on the field being empty (L68), and dated to the stored instant the answer actually went rather than to
// the clock at migration time (L74), so nothing reads as answered today that was answered two days ago.
@MainActor
@Suite("Answered-reply backfill (#2190)")
struct AnsweredReplyBackfillTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, key: String = "k") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "The Pumpkin Singalong at Sakura Park",
                         discipline: "choral", venue: "Sakura Park", performanceDate: "2026-10-31",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    // The live instants, so the test is measured from the store rather than invented (L48).
    private let sheWrote = Date(timeIntervalSince1970: 1_785_891_326)     // 2026-08-04 20:55:26 EDT
    private let heAnswered = Date(timeIntervalSince1970: 1_785_970_178)   // 2026-08-05 18:49:38 EDT
    private let group = "35E15806-C348-4915-8FFE-ADAB4B24A955"
    private let herReply = "19fcf6b9a4dddb0a"

    @discardableResult
    private func waitingContact(_ p: Prospect, _ address: String,
                                answeredAt: Date? = nil, replyArrived: Date? = nil,
                                replyId: String? = nil, sendGroup: String? = nil) -> Recipient {
        let r = Recipient(id: address, email: address, provenance: .act)
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.sendState = .sent
        r.gmailThreadId = "19fceac517b7f2d4"
        r.sendGroupId = sendGroup ?? group
        r.replied = true
        r.repliedAt = replyArrived ?? sheWrote
        r.inboundReplySentAt = replyArrived ?? sheWrote
        r.lastReplyId = replyId ?? herReply
        r.replyFromAddress = "nicolebecker@everyvoicechoirs.org"
        // What the pre-#2170 answer left behind: the frozen copy and the send time, and no stamp.
        if let answeredAt {
            r.sentReplyBody = "Tuesday works, I will bring the 85mm."
            r.replySentAt = answeredAt
        }
        p.addRecipient(r)
        return r
    }

    // The premise, checked rather than assumed: this really is the state Dan's store is in, and the row
    // really does read as waiting before the pass runs (L1).
    @Test func thePremiseHolds_ananasweredRowWithASentAnswerStillAsks() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = waitingContact(p, "chelsea@everyvoicechoirs.org", answeredAt: heAnswered)

        #expect(chelsea.replyHandledAt == nil)
        #expect(chelsea.hasUnhandledReply, "this is the row Dan is looking at")
    }

    // 1. The repair, dated to when he actually answered.
    @Test func itStampsTheRowWithTheInstantTheAnswerWentOut() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = waitingContact(p, "chelsea@everyvoicechoirs.org", answeredAt: heAnswered)

        let changed = AnsweredReplyBackfill.run(in: ctx)

        #expect(changed == 1)
        #expect(chelsea.replyHandledAt == heAnswered,
                "dated to when he answered, not to whenever the migration happened to run (L74)")
        #expect(!chelsea.hasUnhandledReply)
    }

    // 2. And the peer detection put the same reply on, which sent nothing itself. This is row 123 on the
    // live store: no answer of its own, and the reason the show would otherwise stay lit.
    @Test func itStampsThePeerOnTheSameReplyThatSentNothing() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        waitingContact(p, "chelsea@everyvoicechoirs.org", answeredAt: heAnswered)
        let nicole = waitingContact(p, "nbecker@everyvoicechoirs.org")

        let changed = AnsweredReplyBackfill.run(in: ctx)

        #expect(changed == 2)
        #expect(nicole.replyHandledAt == heAnswered)
        #expect(!p.hasUnhandledReply, "the show stops feeding the badge and the OmniFocus task")
    }

    // 3. The failure path. A reply that arrived AFTER the answer went out is a NEW message nobody has
    // answered, and stamping it would silently bury it. This is the case that makes the pass safe to run
    // over a store that has moved on since the defect.
    @Test func aReplyThatArrivedAfterTheAnswerIsLeftAsking() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let sheWroteAgain = heAnswered.addingTimeInterval(3_600)
        let chelsea = waitingContact(p, "chelsea@everyvoicechoirs.org",
                                     answeredAt: heAnswered, replyArrived: sheWroteAgain)

        let changed = AnsweredReplyBackfill.run(in: ctx)

        #expect(changed == 0)
        #expect(chelsea.replyHandledAt == nil)
        #expect(chelsea.hasUnhandledReply, "she has written again since he answered")
    }

    // 4. A contact with no answer anywhere on its conversation is genuinely still waiting, which is the
    // ordinary state of most of the queue. The pass must not treat "field is empty" as the signal (L68).
    @Test func aGenuinelyUnansweredReplyIsUntouched() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let waiting = waitingContact(p, "someone@example.org")

        let changed = AnsweredReplyBackfill.run(in: ctx)

        #expect(changed == 0)
        #expect(waiting.replyHandledAt == nil)
        #expect(waiting.hasUnhandledReply)
    }

    // 5. And an answer on a DIFFERENT conversation on the same show never reaches across.
    @Test func anAnswerInAnotherSendGroupDoesNotStampThisOne() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        waitingContact(p, "chelsea@everyvoicechoirs.org", answeredAt: heAnswered)
        let stranger = waitingContact(p, "boxoffice@everyvoicechoirs.org",
                                      replyId: "19fd000000000000", sendGroup: "A-DIFFERENT-GROUP")

        AnsweredReplyBackfill.run(in: ctx)

        #expect(stranger.replyHandledAt == nil)
        #expect(stranger.hasUnhandledReply)
    }

    // 6. It runs at every launch, so it has to be safe to run twice (and a third time).
    @Test func asecondRunChangesNothing() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = waitingContact(p, "chelsea@everyvoicechoirs.org", answeredAt: heAnswered)
        waitingContact(p, "nbecker@everyvoicechoirs.org")

        #expect(AnsweredReplyBackfill.run(in: ctx) == 2)
        #expect(AnsweredReplyBackfill.run(in: ctx) == 0)
        #expect(AnsweredReplyBackfill.run(in: ctx) == 0)
        #expect(chelsea.replyHandledAt == heAnswered, "the date does not drift on a re-run")
    }

    // 7. A row #2191 has already stamped (answered after the fix shipped) is left exactly as it is.
    @Test func aRowAlreadyStampedIsNotRewritten() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let laterStamp = heAnswered.addingTimeInterval(86_400)
        let chelsea = waitingContact(p, "chelsea@everyvoicechoirs.org", answeredAt: heAnswered)
        chelsea.replyHandledAt = laterStamp

        let changed = AnsweredReplyBackfill.run(in: ctx)

        #expect(changed == 0)
        #expect(chelsea.replyHandledAt == laterStamp)
    }

    // 8. It is wired. A migration nobody calls is indistinguishable from no migration (L3).
    @Test func itIsRegisteredAtLaunch() {
        let source = SourceGuardHelper.source("Overture/Domain/LaunchMigrations.swift")
        #expect(source.contains("AnsweredReplyBackfill.run(in: context)"),
                "the backfill must run at launch or it repairs nothing (#2190, L3)")
    }
}
