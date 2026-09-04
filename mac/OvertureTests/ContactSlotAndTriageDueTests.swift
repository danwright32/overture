import Testing
import Foundation
import SwiftData

// #3422 and #2663: what task a contact earns, and when it is due.
//
// #3422 is the due itself, wired through `OmniFocusSync.desired` and the note it writes: a reply
// triage task is dated from when the reply ARRIVED rather than from a fixed 6:00 PM on its day.
//
// #2663 asked whether a contact's single slot should go to whatever is owed SOONEST rather than to
// whichever branch is written first. That only becomes a real question if a post-event prompt not yet
// owed can earn a task at all, which needs the look-ahead horizon to be live. It was built and then
// REVERSED (Dan, 2026-09-04, in session): earning early would put close-out reminders into OmniFocus up
// to a fortnight before they are due. So #2397's rule stands unchanged, an owed prompt takes the slot,
// and a prompt not yet owed earns nothing, which the last two tests here pin so it cannot come back
// without somebody meeting them (L252).
//
// Every fixture pins BOTH the data and the clock, so real time cannot walk a case into a different
// band or a different side of the horizon (L130).
@MainActor
@Suite("What a contact's OmniFocus slot goes to (#2663, #3422)")
struct ContactSlotAndTriageDueTests {
    private func eastern(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
        return EasternDate.calendar.date(from: c)!
    }

    // A lead whose contact wrote back and has not been answered. `performanceDate` and the reply's
    // arrival are both arguments so each test states the case it is about.
    private func lead(showOn showDay: String, repliedAt: Date, sentAt: Date) -> Prospect {
        let p = Prospect(naturalKey: "a choir|\(showDay)|a hall", groupName: "A Choir",
                         discipline: "music", venue: "A Hall", performanceDate: showDay,
                         sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "t", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .contacted)
        p.sentAt = sentAt
        let r = Recipient(id: "them@example.invalid", email: "them@example.invalid",
                          name: "Them", provenance: .act)
        r.sendState = .sent
        r.sentAt = sentAt
        r.gmailMessageId = "m1"
        r.reopenOnReply(at: repliedAt)
        p.setRecipients([r])
        return p
    }

    // #3422 end to end through `desired`: the task's due is the rule's answer, not 6:00 PM on the
    // arrival day. The 10:12 PM arrival is the one from Dan's own OmniFocus screenshot.
    @Test func aTriageTaskIsDueByTheArrivalRuleRatherThanAFixedSixPm() throws {
        let arrival = eastern(2026, 8, 31, 22, 12)
        let now = eastern(2026, 8, 31, 22, 30)
        let p = lead(showOn: "2026-12-01", repliedAt: arrival, sentAt: eastern(2026, 8, 20, 10, 0))
        let tasks = OmniFocusSync.desired(from: [p], now: now, horizonDays: 14)
        let task = try #require(tasks.first { $0.kind == .replyTriage })
        #expect(task.dueDate == eastern(2026, 9, 1, 9, 0))
        #expect(task.dueDate != eastern(2026, 8, 31, 18, 0), "the old fixed hour")
    }

    // The defer moves with it. Without this the task would be hidden until 11:00 AM on a deadline of
    // 9:00 AM and surface already overdue, which is the same complaint in a narrower window (#3422).
    @Test func aTriageTaskIsNeverHiddenPastItsOwnDeadline() throws {
        let arrival = eastern(2026, 8, 31, 22, 12)
        let p = lead(showOn: "2026-12-01", repliedAt: arrival, sentAt: eastern(2026, 8, 20, 10, 0))
        let tasks = OmniFocusSync.desired(from: [p], now: eastern(2026, 8, 31, 22, 30), horizonDays: 14)
        let task = try #require(tasks.first { $0.kind == .replyTriage })
        #expect(task.deferDate <= task.dueDate)
    }

    // The note has to carry the TIME, or reconcile compares a varying due against a token that can
    // only say the day, calls every task stale, and completes and recreates it for ever (#3422).
    @Test func theNoteCarriesTheDueTimeAndNotJustTheDay() throws {
        let arrival = eastern(2026, 8, 31, 22, 12)
        let p = lead(showOn: "2026-12-01", repliedAt: arrival, sentAt: eastern(2026, 8, 20, 10, 0))
        let tasks = OmniFocusSync.desired(from: [p], now: eastern(2026, 8, 31, 22, 30), horizonDays: 14)
        let task = try #require(tasks.first { $0.kind == .replyTriage })
        let expected = OmniFocusSync.dueNotePrefix + OmniFocusDueToken.string(from: task.dueDate)
        #expect(task.note.contains(expected))
        #expect(task.note.contains("09:00"))
    }

    // A contact owing triage today, on a show that has NOT happened yet, earns the triage task. Its
    // post-event prompt is not owed until the day after the show, and a prompt that is not owed earns
    // nothing at all, so there is no competition for the slot.
    @Test func aContactOwingTriageOnAShowStillAheadEarnsTheTriageTask() throws {
        let arrival = eastern(2026, 8, 31, 9, 0)          // triage due 1:00 PM the same day
        let now = eastern(2026, 8, 31, 10, 0)
        let p = lead(showOn: "2026-09-05", repliedAt: arrival, sentAt: eastern(2026, 8, 20, 10, 0))
        let tasks = OmniFocusSync.desired(from: [p], now: now, horizonDays: 14)
        #expect(tasks.count == 1, "one task per contact")
        let task = try #require(tasks.first)
        #expect(task.kind == .replyTriage)
        #expect(task.dueDate == eastern(2026, 8, 31, 13, 0))
    }

    // The other side, so this is not a test that only ever sees one branch win. Once the show is PAST
    // the prompt is already owed, and #2397's decision stands untouched: what Dan owes then is an
    // ending rather than an answer. #2663 is about work not yet owed, so it does not reach this case,
    // and this is here to prove the older decision survived rather than being quietly reversed (L542).
    @Test func aPostEventPromptAlreadyOwedStillOutranksTriage() throws {
        let arrival = eastern(2026, 8, 31, 9, 0)
        let now = eastern(2026, 8, 31, 10, 0)
        let p = lead(showOn: "2026-08-01", repliedAt: arrival, sentAt: eastern(2026, 7, 20, 10, 0))
        let tasks = OmniFocusSync.desired(from: [p], now: now, horizonDays: 14)
        #expect(tasks.count == 1)
        #expect(tasks.first?.kind == .postEventPrompt)
    }

    // #3422's last section. The staged Debug lead set `replied` without stamping any arrival, so its
    // `replyArrivedAt` was nil and the triage due fell back to `sentAt`: a deadline measured from when
    // Dan SENT rather than from anything arriving. The rule would have been working and reading as
    // broken on the one lead anybody uses to check it.
    @Test func theStagedDebugLeadRecordsAnArrivalTheWayARealReplyDoes() throws {
        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let p = DebugStaging.stageReminderDueLead(in: ctx, now: eastern(2026, 8, 31, 14, 0))
        let r = try #require(p.recipients.first)
        #expect(r.replyArrivedAt != nil, "the fixture would fall back to sentAt, which is the wrong event")
        #expect(r.hasUnhandledReply, "and it must still be the case the triage task exists for")
    }

    // #2663 REVERSED, and pinned so it cannot be reintroduced without somebody meeting this test.
    //
    // A close-out prompt coming due next week earns NOTHING today, even though it is inside the
    // look-ahead window. Making it earn early was built and then reversed: Dan's call, 2026-09-04, in
    // this session, on being shown that it would put close-out reminders into OmniFocus up to a
    // fortnight before they are due. The look-ahead horizon therefore still has never applied to this
    // branch, which is a decision rather than an oversight (L346).
    @Test func aPromptNotYetOwedEarnsNothingEvenInsideTheHorizon() throws {
        let now = eastern(2026, 8, 31, 10, 0)
        let p = lead(showOn: "2026-09-05", repliedAt: eastern(2026, 8, 20, 9, 0), sentAt: eastern(2026, 8, 10, 10, 0))
        // Answered, so no triage competes and this is about the post-event branch alone.
        p.recipients.first?.replyHandledAt = eastern(2026, 8, 21, 9, 0)
        #expect(OmniFocusSync.desired(from: [p], now: now, horizonDays: 14).isEmpty)
    }

    // The positive control for the test above: the SAME lead, once the show has passed, does earn its
    // prompt. Without it, "earns nothing" is equally true of a lead that could never earn anything and
    // the test would pass against a branch that is simply broken (L159).
    @Test func theSameLeadDoesEarnItsPromptOnceTheShowHasPassed() throws {
        let p = lead(showOn: "2026-09-05", repliedAt: eastern(2026, 8, 20, 9, 0), sentAt: eastern(2026, 8, 10, 10, 0))
        p.recipients.first?.replyHandledAt = eastern(2026, 8, 21, 9, 0)
        let tasks = OmniFocusSync.desired(from: [p], now: eastern(2026, 9, 6, 10, 0), horizonDays: 14)
        #expect(tasks.first?.kind == .postEventPrompt)
    }
}
