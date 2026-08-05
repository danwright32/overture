import Testing
import Foundation
import SwiftData

// #2111 and #2116: a reminder date must be anchored to the instant the WORK arrived, never recomputed
// from the clock at render time. Three branches of ConversationReminder.nextReminderDate used to
// `return now`, so every draw of the queue moved the date forward with the clock: the card re-filed
// itself under today, could never read as overdue, and could never sort above genuinely fresh work.
//
// Dan hit it on 2026-08-05: Nicole Becker replied 2026-08-04 at 20:56 Eastern (measured in the live
// store, ZREPLIEDAT = 2026-08-05 00:56:30 UTC) and her card sat under Aug 5 saying "Reach out now".
//
// The property that actually broke is CLOCK INVARIANCE, so it is tested directly rather than through a
// single pinned instant: hold the inputs still, move `now` forward a day, and the answer must not move.
// A test pinned to one clock passes for all three defects, which is why none of them was caught.
@Suite("Reminder dates age with the work, not the clock")
struct ReminderDateAgesWithTheWorkTests {
    // 2026-06-15 16:00 UTC = 12:00 EDT, so EasternDate.today(now) == "2026-06-15".
    private var now: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 16))!
    }
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }
    private func daysAhead(_ d: Double) -> Date { now.addingTimeInterval(d * 86_400) }

    // MARK: the three branches, each anchored to its own real instant

    // #2111, Dan's case: the day the reply landed, not the day he happens to be looking.
    @Test func anUnhandledReplyIsDueOnTheDayItArrived() {
        let arrived = daysAgo(1)
        #expect(ConversationReminder.nextReminderDate(
            state: nil, setAt: nil, remindedAt: nil, performanceDate: nil, isClosed: false,
            hasUnhandledReply: true, repliedAt: arrived, source: nil, now: now) == arrived)
    }

    // #2116: an AI guess is due from the moment it was guessed, so an untriaged suggestion ages.
    @Test func anAiSuggestedStateIsDueFromWhenItWasGuessed() {
        let guessedAt = daysAgo(3)
        #expect(ConversationReminder.nextReminderDate(
            state: .wantsToBook, setAt: guessedAt, remindedAt: nil, performanceDate: "2026-12-01",
            isClosed: false, hasUnhandledReply: false, repliedAt: nil, source: .auto, now: now) == guessedAt)
    }

    // #2116: the closing note is due the day after the show, so one owed for a week reads a week overdue.
    @Test func aPostEventClosingNoteIsDueTheDayAfterTheShow() {
        // Show was 2026-06-10; the note came due at Eastern midnight opening 2026-06-11.
        let expected = EasternDate.date(from: "2026-06-11")
        #expect(ConversationReminder.nextReminderDate(
            state: .interested, setAt: daysAgo(30), remindedAt: nil, performanceDate: "2026-06-10",
            isClosed: false, hasUnhandledReply: false, repliedAt: nil, source: .manual, now: now) == expected)
    }

    // MARK: the property that broke, over every branch at once (the guard against a fourth instance)

    // Same inputs, two clocks a day apart, same answer. Each case below returned `now` before the fix,
    // so each one moved a full day and this expectation failed for all three.
    @Test(arguments: [
        "unhandled reply", "ai suggested state", "post-event closing note", "timed interval track",
    ])
    func aReminderDateDoesNotMoveWhenOnlyTheClockMoves(_ branch: String) {
        let later = now.addingTimeInterval(86_400)
        func date(at clock: Date) -> Date? {
            switch branch {
            case "unhandled reply":
                return ConversationReminder.nextReminderDate(
                    state: nil, setAt: nil, remindedAt: nil, performanceDate: nil, isClosed: false,
                    hasUnhandledReply: true, repliedAt: daysAgo(1), source: nil, now: clock)
            case "ai suggested state":
                return ConversationReminder.nextReminderDate(
                    state: .wantsToBook, setAt: daysAgo(3), remindedAt: nil, performanceDate: "2026-12-01",
                    isClosed: false, hasUnhandledReply: false, repliedAt: nil, source: .auto, now: clock)
            case "post-event closing note":
                return ConversationReminder.nextReminderDate(
                    state: .interested, setAt: daysAgo(30), remindedAt: nil, performanceDate: "2026-06-10",
                    isClosed: false, hasUnhandledReply: false, repliedAt: nil, source: .manual, now: clock)
            default:
                // The already-correct branch, held here so the property covers the WHOLE function and a
                // future edit that reaches for `now` on the timed track fails this test too.
                return ConversationReminder.nextReminderDate(
                    state: .interested, setAt: daysAgo(3), remindedAt: nil, performanceDate: nil,
                    isClosed: false, hasUnhandledReply: false, repliedAt: nil, source: .manual, now: clock)
            }
        }
        #expect(date(at: now) != nil, "\(branch) should be scheduled at all")
        #expect(date(at: now) == date(at: later), "\(branch) moved with the clock")
    }

    // MARK: the anchors must not push work into the future

    // A reply timestamped ahead of the clock is skew, not a reason to stop asking: it still reads as due
    // now. Without the clamp the card would silently leave the due list until the clock caught up.
    @Test func aReplyStampedInTheFutureIsStillDueNow() {
        let date = ConversationReminder.nextReminderDate(
            state: nil, setAt: nil, remindedAt: nil, performanceDate: nil, isClosed: false,
            hasUnhandledReply: true, repliedAt: daysAhead(2), source: nil, now: now)
        #expect(date == now)
        #expect(ConversationReminder.reminder(
            state: nil, setAt: nil, remindedAt: nil, performanceDate: nil, isClosed: false,
            hasUnhandledReply: true, repliedAt: daysAhead(2), source: nil, now: now)?.kind == .needsState)
    }

    // A reply with no recorded timestamp at all (an older row written before the field was filled) keeps
    // the old behaviour rather than dropping out of the due list.
    @Test func aReplyWithNoTimestampFallsBackToNow() {
        #expect(ConversationReminder.nextReminderDate(
            state: nil, setAt: nil, remindedAt: nil, performanceDate: nil, isClosed: false,
            hasUnhandledReply: true, repliedAt: nil, source: nil, now: now) == now)
    }

    // MARK: still due, and still classified the same way

    // The anchors move only WHERE the card groups, never whether it is due or what it says. Each of the
    // three stays due with the same kind it had before, so the fix cannot quietly silence a reminder.
    @Test func theAnchoredBranchesAreStillDueWithTheSameKind() {
        #expect(ConversationReminder.reminder(
            state: nil, setAt: nil, remindedAt: nil, performanceDate: nil, isClosed: false,
            hasUnhandledReply: true, repliedAt: daysAgo(1), source: nil, now: now)?.kind == .needsState)
        #expect(ConversationReminder.reminder(
            state: .wantsToBook, setAt: daysAgo(3), remindedAt: nil, performanceDate: "2026-12-01",
            isClosed: false, hasUnhandledReply: false, repliedAt: nil, source: .auto,
            now: now)?.kind == .suggested(.wantsToBook))
        #expect(ConversationReminder.reminder(
            state: .interested, setAt: daysAgo(30), remindedAt: nil, performanceDate: "2026-06-10",
            isClosed: false, hasUnhandledReply: false, repliedAt: nil, source: .manual,
            now: now)?.kind == .closing)
    }
}

// The same defect where Dan actually saw it: the reached-out list, which groups its rows under a date
// heading and sorts soonest first. Anchoring the reply is what puts the card under the day it arrived
// and above work that is merely due today.
@MainActor
@Suite("Reached-out queue dates a reply on the day it arrived")
struct ReachedOutQueueRepliedDateTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func makeShow(_ ctx: ModelContext, group: String) -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "choral", venue: "V",
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        ctx.insert(p)
        return p
    }

    private func makeRecipient(_ ctx: ModelContext, on p: Prospect, id: String,
                               sentAt: Date, repliedAt: Date?) -> Recipient {
        let r = Recipient(id: id, email: id, provenance: .act)
        r.sentAt = sentAt
        r.sendState = .sent
        r.gmailMessageId = "msg-\(id)"
        if let repliedAt {
            r.replied = true
            r.repliedAt = repliedAt
        }
        p.setRecipients(p.recipients + [r])
        return r
    }

    private var now: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    // Dan's report: a reply from yesterday evening must group under yesterday, not today.
    @Test func aReplyFromYesterdayIsDatedYesterday() throws {
        let ctx = ModelContext(try container())
        let p = makeShow(ctx, group: "Every Voice")
        let arrived = now.addingTimeInterval(-15 * 3_600)   // yesterday evening
        let r = makeRecipient(ctx, on: p, id: "nbecker@everyvoicechoirs.org",
                              sentAt: now.addingTimeInterval(-6 * 86_400), repliedAt: arrived)
        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: now) == arrived)
    }

    // The consequence Dan cares about: an unanswered reply outranks work that only came due today,
    // instead of being shuffled in among it every time the list is drawn.
    @Test func anOlderReplySortsAboveWorkDueToday() throws {
        let ctx = ModelContext(try container())
        let older = makeShow(ctx, group: "Replied Two Days Ago")
        _ = makeRecipient(ctx, on: older, id: "old@example.com",
                          sentAt: now.addingTimeInterval(-9 * 86_400),
                          repliedAt: now.addingTimeInterval(-2 * 86_400))
        let fresh = makeShow(ctx, group: "Replied Just Now")
        _ = makeRecipient(ctx, on: fresh, id: "new@example.com",
                          sentAt: now.addingTimeInterval(-9 * 86_400), repliedAt: now)

        let rows = ReachedOutQueue.activeWithDates(from: [fresh, older], now: now)
        #expect(rows.map { $0.prospect.groupName } == ["Replied Two Days Ago", "Replied Just Now"])
    }

    // The overdue reading itself: the row must not silently re-file itself forward as days pass.
    @Test func anUnansweredReplyStaysDatedAsTheDaysPass() throws {
        let ctx = ModelContext(try container())
        let p = makeShow(ctx, group: "Still Waiting")
        let arrived = now.addingTimeInterval(-15 * 3_600)
        let r = makeRecipient(ctx, on: p, id: "waiting@example.com",
                              sentAt: now.addingTimeInterval(-6 * 86_400), repliedAt: arrived)
        let threeDaysOn = now.addingTimeInterval(3 * 86_400)
        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: threeDaysOn) == arrived)
        #expect(ReachedOutQueue.isDueNow(next: arrived, now: threeDaysOn))
    }
}
