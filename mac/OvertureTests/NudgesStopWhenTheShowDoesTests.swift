import Testing
import Foundation
import SwiftData

// #2645: a follow-up nudge was still scheduled for a show that had already happened.
//
// Measured on the live store, 2026-08-13: recipient 147 (smokeringquartet@example.com), pitched Tue Aug 11
// at 9:52pm Eastern, `FollowUpConfig.gapDays` 6, so the next nudge came due Mon Aug 17. The show
// performed Aug 13. By the time that nudge fired the show would have been four days in the past, and the
// nudge body is written to chase a pitch about an UPCOMING performance.
//
// Usually this was masked rather than absent: `PostEventPrompt` comes due the day after the show and
// sending the closing note records `neverHeardBack`, which takes the row off the stage before the nudge
// date arrives. So it was only reachable when the post-event prompt sat unanswered for longer than the
// remaining gap, which is exactly when Dan is behind.
//
// Dan's call, asked directly whether a nudge chasing a show that has been and gone is wrong or fine: it
// is wrong. After the performance the only things Overture offers are the closing note and the close-out.
@MainActor
@Suite("Nudges stop when the show does (#2645)")
struct NudgesStopWhenTheShowDoesTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    // The live row's shape: pitched Aug 11 21:52 Eastern, nudge due Aug 17.
    @discardableResult
    private func pitched(_ ctx: ModelContext, showDate: String?, runEndDate: String? = nil)
        -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "k-\(showDate ?? "none")-\(runEndDate ?? "-")",
                         groupName: "Smoke Ring Quartet", discipline: "music", venue: "V",
                         performanceDate: showDate, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.runEndDate = runEndDate
        let pitchedAt = EasternDate.date(from: "2026-08-11")!.addingTimeInterval(21 * 3600 + 52 * 60)
        p.sentAt = pitchedAt
        ctx.insert(p)
        let r = Recipient(id: "a@b.com", email: "a@b.com", provenance: .manual)
        r.sendState = .sent
        r.sentAt = pitchedAt
        r.gmailMessageId = "<real@mail.gmail.com>"
        r.prospect = p
        ctx.insert(r)
        return (p, r)
    }

    private func day(_ s: String) -> Date { EasternDate.date(from: s)! }

    // MARK: the gate

    @Test func aShowStillAheadKeepsItsNudge() throws {
        let ctx = try context()
        let (p, r) = pitched(ctx, showDate: "2026-08-13")
        #expect(FollowUp.isAwaitingNudge(r, in: p, now: day("2026-08-12")))
    }

    // The night itself is not over until it is over. A run opening tonight has not opened yet, which is
    // the same edge `PostEventPrompt` draws by dating itself the day AFTER.
    @Test func theShowsOwnDayStillCounts() throws {
        let ctx = try context()
        let (p, r) = pitched(ctx, showDate: "2026-08-13")
        #expect(FollowUp.isAwaitingNudge(r, in: p, now: day("2026-08-13")))
    }

    @Test func aShowThatHasBeenAndGoneIsNoLongerNudged() throws {
        let ctx = try context()
        let (p, r) = pitched(ctx, showDate: "2026-08-13")
        #expect(!FollowUp.isAwaitingNudge(r, in: p, now: day("2026-08-14")))
    }

    // MARK: what "passed" means for a multi-night run

    // The run's END, never its first night. Reading the first date here would silently stop nudging every
    // multi-night run from its opening night onwards, which is a far worse defect than the one this
    // fixes and is invisible in exactly the same way.
    @Test func aRunStillPlayingIsStillNudgedAfterItsOpeningNight() throws {
        let ctx = try context()
        let (p, r) = pitched(ctx, showDate: "2026-08-13", runEndDate: "2026-08-20")
        #expect(FollowUp.isAwaitingNudge(r, in: p, now: day("2026-08-16")))   // mid-run
        #expect(FollowUp.isAwaitingNudge(r, in: p, now: day("2026-08-20")))   // closing night
    }

    @Test func aRunThatHasFinishedIsNoLongerNudged() throws {
        let ctx = try context()
        let (p, r) = pitched(ctx, showDate: "2026-08-13", runEndDate: "2026-08-20")
        #expect(!FollowUp.isAwaitingNudge(r, in: p, now: day("2026-08-21")))
    }

    // MARK: an undated show

    // "Date to be confirmed" is an ordinary listing state, not a show in the past (#798). A nil last
    // night must not be swept up by a comparison that answers false for everything.
    @Test func anUndatedShowKeepsNudging() throws {
        let ctx = try context()
        let (p, r) = pitched(ctx, showDate: nil)
        #expect(FollowUp.isAwaitingNudge(r, in: p, now: day("2027-01-01")))
    }

    // MARK: one predicate, every surface

    // The Follow-ups list, the row's control and the send path must agree about who is due, or the count
    // promises rows the button will not act on (L16). Asserted through the three entry points rather than
    // by reading `isAwaitingNudge` three times, because agreeing on the predicate is the claim.
    @Test func theListTheControlAndTheSendPathAllStop() async throws {
        let ctx = try context()
        let (p, r) = pitched(ctx, showDate: "2026-08-13")
        let afterTheShow = day("2026-08-18")   // past the show AND past the nudge date of Aug 17

        // Non-vacuity: the nudge really would have been due on this date but for the show having passed,
        // so this fixture stands for the live row rather than for a contact that was never eligible (L48).
        #expect(FollowUp.isDue(eligible: true, sentAt: r.sentAt, lastFollowUpAt: r.lastFollowUpAt,
                               followUpCount: r.followUpCount, remindedAt: r.nudgeRemindedAt,
                               now: afterTheShow))

        #expect(FollowUp.dueRecipients(from: [p], now: afterTheShow).isEmpty)
        #expect(ReachedOutAction.of(r, in: p, now: afterTheShow, today: "2026-08-18") != .sendNudge)
        #expect(await SendService.sendFollowUp(r, of: p, now: afterTheShow,
                                               sender: RefusingSender()) == false)
        #expect(r.followUpCount == 0)
    }

    // And the row does not count down to a nudge it will never send.
    @Test func theRowStopsCountingDownToTheNudge() throws {
        let ctx = try context()
        let (p, r) = pitched(ctx, showDate: "2026-08-13")
        let next = ReachedOutQueue.nextActionableMoment(for: r, of: p, now: day("2026-08-14"))
        // What is left is the post-event prompt, which is due, never the Aug 17 nudge.
        #expect(next == day("2026-08-14"))
    }

    // MARK: the siblings

    // The OTHER clocks that pace an outbound send. Each is asked the question this issue asks: can it
    // come due after the show?
    //
    // The form decision clock cannot pace PAST the show, because it IS the show's own night (#2169): Dan
    // does not chase a form, so the night is when the question becomes answerable. For an undated show it
    // falls back to the pitch plus the gap, which is the case where "after the show" is unknowable.
    @Test func theFormDecisionClockIsTheNightItselfSoItCannotOutliveTheShow() throws {
        let ctx = try context()
        let (p, r) = pitched(ctx, showDate: "2026-08-13")
        r.outreachChannel = .contactForm
        r.formOutreachRecordedAt = day("2026-08-11")
        let next = try #require(ReachedOutQueue.nextActionableMoment(for: r, of: p, now: day("2026-08-01")))
        #expect(next <= day("2026-08-13"))
    }

    // The reply-answer track SHOULD outlive the show and is deliberately untouched: somebody wrote to Dan,
    // and a performance passing does not make their message not need an answer. Stated as a test so the
    // exemption is a decision rather than an omission.
    @Test func answeringAReplyIsStillOfferedAfterTheShow() throws {
        let ctx = try context()
        let (p, r) = pitched(ctx, showDate: "2026-08-13")
        r.reopenOnReply(at: day("2026-08-12"))
        let next = try #require(ReachedOutQueue.nextActionableMoment(for: r, of: p, now: day("2026-08-18")))
        #expect(next <= day("2026-08-18"))
        #expect(r.hasUnhandledReply)
    }
}

// Refuses every send, so a test asserting nothing goes out cannot be satisfied by a send that merely
// succeeded quietly.
private struct RefusingSender: MailSender {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        Issue.record("a nudge reached the sender for a show that has already happened")
        throw MailSenderError.notConfigured
    }
}
