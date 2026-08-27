import Testing
import Foundation
import SwiftData

// #2550: the reached-out row's timing TEXT and its ACTION were decided by two different rules.
//
// The text read `ReachedOutQueue.nextReachOut`, which folds in #2397's FLOOR (an open pitch pinned to the
// show's own date). The floor is a SORT anchor, not a due date: its whole job is to stop a live pitch
// falling off the stage, and it says nothing about anything being owed. The button read
// `ReachedOutAction.of`, which offers a control only when something is genuinely sendable or askable.
//
// So on the show's own night the label printed "Reach out now" in rust beside a row whose only control was
// "Close this out". Dan, 2026-08-11 21:42: "it tells me to reach out now but doesn't actually let me? How
// does it expect me to reach out". L109: a row must not instruct where it cannot act.
//
// These tests pin the SLOT against the ACTION rather than against either one's current rendering, so the
// two cannot drift apart again (L16: the label and the control answer from one predicate).
@MainActor
@Suite("Reached out timing slot")
struct ReachedOutTimingSlotTests {
    private let today = "2026-08-11"
    // 21:42 Eastern on the show's own night, which is when Dan read the row.
    private var now: Date { EasternDate.date(from: "2026-08-11")!.addingTimeInterval(21 * 3_600 + 42 * 60) }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func makeShow(_ ctx: ModelContext, day: String?, group: String = "Devin Marlowe") -> Prospect {
        let p = Prospect(naturalKey: "\(group)|\(day ?? "none")", groupName: group, discipline: "jazz",
                         venue: "V", performanceDate: day, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func makeRecipient(_ ctx: ModelContext, on p: Prospect, sentAt: Date,
                               id: String = "devin@devinmarlowe.example") -> Recipient {
        let r = Recipient(id: id, email: id, provenance: .act)
        r.sentAt = sentAt
        r.sendState = .sent
        // A genuine send always stamps a Gmail message id, which is what hasProvenOutreach demands.
        r.gmailMessageId = "msg-\(id)"
        p.recipients.append(r)
        return r
    }

    // The row Dan actually read. The floor pins it at tonight, nothing is owed, and the slot must say so.
    @Test func aShowOnItsOwnNightNeverSaysReachOutNowWithNothingToPress() throws {
        let ctx = ModelContext(try container())
        let p = makeShow(ctx, day: "2026-08-11")
        let r = makeRecipient(ctx, on: p, sentAt: EasternDate.date(from: "2026-08-10")!)

        // The fold that SORTS the row is pinned at the show by the floor, and stays that way: a live pitch
        // vanishing from the only surface that tracks it is the worse defect (L45).
        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: now) == EasternDate.date(from: "2026-08-11"))
        // And there is genuinely nothing to press.
        #expect(ReachedOutAction.of(r, in: p, now: now, today: today) == .none)

        // #2646: and it counts down to the NEAREST owed moment, which is the closing note due at Eastern
        // midnight tomorrow, not the nudge six days after the pitch.
        //
        // This assertion used to read "in 5 days", and that is worth naming rather than quietly editing:
        // #2550 fixed the label to read from what is OWED instead of from the sort key, and pinned the
        // answer that Dan then reported as wrong two days later (#2646). It was wrong for a reason #2550
        // could not see from here, one clock lower down: `PostEventPrompt.nextPromptDate` refused to name
        // its own date until that date had arrived, so the `min` over the clocks had nothing to compare
        // the nudge against and this test recorded the survivor as correct.
        #expect(ReachedOutQueue.timingLabel(for: r, of: p, now: now, today: today) == "in 1 day")
    }

    // The nudge clock the LABEL reads must be the one the ACTION reads, stand-down included. Before #2550
    // the label used `Recipient.isAwaitingFollowUp` while the action used `FollowUp.isAwaitingNudge`, so a
    // contact Dan had stood down still printed "Reach out now" beside no control at all.
    @Test func aStoodDownContactIsNotToldToReachOutNow() throws {
        let ctx = ModelContext(try container())
        let p = makeShow(ctx, day: "2026-09-30")
        let r = makeRecipient(ctx, on: p, sentAt: now.addingTimeInterval(-20 * 86_400))
        r.outreachStoodDownAt = now.addingTimeInterval(-86_400)

        #expect(ReachedOutAction.of(r, in: p, now: now, today: today) == .none)
        #expect(ReachedOutQueue.timingLabel(for: r, of: p, now: now, today: today) != "Reach out now")
    }

    // Same class again: "remind me later" moves the nudge clock without pretending a nudge was sent
    // (#1740). The action honoured it; the label did not, and read overdue the moment it was pressed.
    @Test func remindMeLaterMovesTheLabelAndTheControlTogether() throws {
        let ctx = ModelContext(try container())
        let p = makeShow(ctx, day: "2026-09-30")
        let r = makeRecipient(ctx, on: p, sentAt: now.addingTimeInterval(-20 * 86_400))
        r.nudgeRemindedAt = now.addingTimeInterval(-86_400)   // reminded yesterday: due again in 5 days

        #expect(ReachedOutAction.of(r, in: p, now: now, today: today) == .none)
        #expect(ReachedOutQueue.timingLabel(for: r, of: p, now: now, today: today) == "in 5 days")
    }

    // A pitch with no clock left at all, still held on the stage by the floor. There is nothing to count
    // down to, so the slot says what the row is actually waiting on rather than inventing a countdown.
    //
    // The shape is the one #2170 settled: Dan ANSWERED the reply, which "clears the pressure WITHOUT
    // removing the row". The nudges are deliberately NOT spent, because a spent row is caught by #2398's
    // own marker one branch earlier and would never reach this sentence (L48: a fixture must stand for a
    // state that can occur).
    //
    // #2646 changed what it takes to reach this state, and the fixture had to move with it. Answering the
    // reply used to be enough, because the post-event clock stayed silent until the show had passed. Now
    // that it names its date, a replied and answered row on a future show DOES have something owed: the
    // close-out, due the day after the show. So the row that genuinely has no clock left is one where the
    // post-event track is closed too, which is Dan standing the closing note down by hand ("not sent but
    // also done", #1740). Without this the test would have been kept green by weakening it, which is the
    // same as deleting the coverage of a state the app still reaches.
    @Test func aRowHeldOpenOnlyByTheFloorSaysWhatItIsWaitingOn() throws {
        let ctx = ModelContext(try container())
        let p = makeShow(ctx, day: "2026-09-30")
        let r = makeRecipient(ctx, on: p, sentAt: now.addingTimeInterval(-20 * 86_400))
        r.replied = true
        r.repliedAt = now.addingTimeInterval(-10 * 86_400)        // replyArrivedAt derives from this
        r.replyHandledAt = now.addingTimeInterval(-9 * 86_400)    // Dan wrote back
        r.closingNoteStoodDownAt = now.addingTimeInterval(-86_400)   // and closed the post-event track too

        #expect(!SpentNudges.isSpent(show: p))                   // not the spent-marker branch
        #expect(!r.hasUnhandledReply)                            // nobody is waiting on Dan
        #expect(ReachedOutQueue.nextActionableMoment(for: r, of: p, now: now) == nil)
        #expect(ReachedOutAction.of(r, in: p, now: now, today: today) == .none)
        #expect(ReachedOutQueue.timingLabel(for: r, of: p, now: now, today: today)
                == ReachedOutQueue.heldOpenLabel)
        // And it is still on the stage, which is the whole reason the floor exists (L45).
        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: now) != nil)
    }

    // #2646, Dan's call 2026-08-13: the same row WITHOUT the hand stand-down counts down to the close-out
    // rather than saying nothing is due. Asked directly whether a row weeks from its show should stay quiet
    // or name the moment, he chose the countdown: one rule everywhere, and the slot always names the
    // nearest thing actually owed.
    @Test func aReplyAnsweredRowCountsDownToItsCloseOut() throws {
        let ctx = ModelContext(try container())
        let p = makeShow(ctx, day: "2026-09-30")
        let r = makeRecipient(ctx, on: p, sentAt: now.addingTimeInterval(-20 * 86_400))
        r.replied = true
        r.repliedAt = now.addingTimeInterval(-10 * 86_400)
        r.replyHandledAt = now.addingTimeInterval(-9 * 86_400)

        // The close-out prompt, the day after the show, is the only clock left and it is now visible.
        #expect(ReachedOutQueue.nextActionableMoment(for: r, of: p, now: now)
                == EasternDate.date(from: "2026-10-01"))
        #expect(ReachedOutQueue.timingLabel(for: r, of: p, now: now, today: today)
                != ReachedOutQueue.heldOpenLabel)
        // Still nothing to press today, which is the point of a countdown rather than an instruction.
        #expect(ReachedOutAction.of(r, in: p, now: now, today: today) == .none)
    }

    // A nudge that IS due still reads "Reach out now", beside the button that sends it. The fix must not
    // silence the urgency it was written to make honest.
    @Test func aDueNudgeStillReadsReachOutNowBesideItsButton() throws {
        let ctx = ModelContext(try container())
        let p = makeShow(ctx, day: "2026-09-30")
        let r = makeRecipient(ctx, on: p, sentAt: now.addingTimeInterval(-10 * 86_400))

        #expect(ReachedOutAction.of(r, in: p, now: now, today: today) == .sendNudge)
        #expect(ReachedOutQueue.timingLabel(for: r, of: p, now: now, today: today) == "Reach out now")
    }

    // The row paints its timing text rust on "due now", so the urgency has to move with the text. A show
    // on its own night with nothing owed is not urgent.
    @Test func urgencyFollowsWhatIsOwedNotTheSortFloor() throws {
        let ctx = ModelContext(try container())
        let quiet = makeShow(ctx, day: "2026-08-11", group: "Quiet")
        let quietR = makeRecipient(ctx, on: quiet, sentAt: EasternDate.date(from: "2026-08-10")!)
        // Held at tonight by the floor, so the SORT key reads due now...
        #expect(ReachedOutQueue.isDueNow(next: ReachedOutQueue.nextReachOut(for: quietR, of: quiet, now: now)!,
                                         now: now))
        // ...and the ROW is not.
        #expect(!ReachedOutQueue.isDueNow(for: quietR, of: quiet, now: now))

        let owed = makeShow(ctx, day: "2026-09-30", group: "Owed")
        let owedR = makeRecipient(ctx, on: owed, sentAt: now.addingTimeInterval(-10 * 86_400))
        #expect(ReachedOutQueue.isDueNow(for: owedR, of: owed, now: now))
    }

    // The invariant, asserted over every shape the row can take rather than over the five cases above: the
    // slot may only instruct where the row can act. This is the guard #2550 exists to install.
    @Test func theSlotNeverInstructsWhereTheRowCannotAct() throws {
        let ctx = ModelContext(try container())
        let days = ["2026-08-11", "2026-08-12", "2026-09-30", "2026-07-01"]
        let sentAgo = [1.0, 6.0, 10.0, 40.0]
        var checked = 0
        for day in days {
            for ago in sentAgo {
                for count in 0...2 {
                    for stoodDown in [false, true] {
                        let p = makeShow(ctx, day: day, group: "G\(day)-\(ago)-\(count)-\(stoodDown)")
                        let r = makeRecipient(ctx, on: p, sentAt: now.addingTimeInterval(-ago * 86_400))
                        r.followUpCount = count
                        if stoodDown { r.outreachStoodDownAt = now.addingTimeInterval(-86_400) }

                        let slot = ReachedOutQueue.timingLabel(for: r, of: p, now: now, today: today)
                        let action = ReachedOutAction.of(r, in: p, now: now, today: today)
                        // "Reach out now" is an instruction. It may only appear where a control can carry it
                        // out, which on this row means an action that puts an email in front of Dan.
                        if slot == "Reach out now" {
                            #expect(action.sendsAnEmail,
                                    "slot instructed a reach-out on a row whose action was \(action) (day \(day), sent \(ago)d ago, \(count) nudges, stoodDown \(stoodDown))")
                        }
                        checked += 1
                    }
                }
            }
        }
        // The matrix is only worth anything if it ran: a loop over an empty list passes while checking
        // nothing (L98).
        #expect(checked == days.count * sentAgo.count * 3 * 2)
    }
}
