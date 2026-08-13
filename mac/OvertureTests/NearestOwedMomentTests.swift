import Testing
import Foundation
import SwiftData

// #2646: the reached out row counted down to the FAR date and skipped the nearer one.
//
// Dan, 2026-08-13, on the Neyla Pekarek row: it read "in 5 days" while the show performed that same
// night. The five days was the follow-up nudge (pitched Aug 11 at 9:52pm Eastern, `gapDays` 6, so due
// Aug 17). The thing actually owed next was the closing note, due at Eastern midnight on Aug 14, one day
// out. The row would have jumped from "in 5 days" straight to "Reach out now" overnight, with nothing
// said today about the thing about to land.
//
// `ReachedOutQueue.nextActionableMoment` takes the `min` of its clocks, and one of them refused to name
// its own date until that date had already arrived (`guard now >= dayAfter else { return nil }`). A clock
// reporting nil is indistinguishable from a clock with nothing to report, so the `min` landed on the
// farther nudge. `PostEventPrompt.nextPromptDate`'s own comment called itself the single source of truth
// for WHEN a prompt is due, which is the one question it declined to answer while the answer was still in
// the future.
@MainActor
@Suite("The countdown names the nearest owed moment (#2646)")
struct NearestOwedMomentTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    // The live row, as measured on 2026-08-13: pitched Aug 11, performing Aug 13, nudge due Aug 17,
    // closing note due Aug 14.
    @discardableResult
    private func neylaShaped(_ ctx: ModelContext, showDate: String = "2026-08-13") -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "k", groupName: "Smoke Ring Quartet", discipline: "music", venue: "V",
                         performanceDate: showDate, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
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

    // MARK: the clock names its own date

    // The split this issue asks for: `nextPromptDate` answers WHEN, always, and only `prompt(for:)`
    // answers whether it is due yet.
    @Test func theClockNamesADateThatHasNotArrivedYet() throws {
        let ctx = try context()
        let (p, r) = neylaShaped(ctx)

        // The day before the show, with the prompt still a day and a half away.
        #expect(PostEventPrompt.nextPromptDate(for: r, of: p) == day("2026-08-14"))
        #expect(PostEventPrompt.prompt(for: r, of: p, now: day("2026-08-13")) == nil)

        // And once it arrives, it is due.
        #expect(PostEventPrompt.prompt(for: r, of: p, now: day("2026-08-14"))?.kind == .closingNote)
    }

    // Everything that is genuinely "there is no prompt at all" must keep answering nil, or this fix
    // trades a silent clock for a nagging one. Each of these is a different reason, checked separately so
    // a single over-broad guard cannot pass this by accident.
    @Test func aPromptThatDoesNotApplyIsStillNil() throws {
        let ctx = try context()

        let (booked, bookedContact) = neylaShaped(ctx)
        booked.showOutcome = .booked
        #expect(PostEventPrompt.nextPromptDate(for: bookedContact, of: booked) == nil)

        let (dismissed, dismissedContact) = neylaShaped(ctx)
        dismissed.status = .dismissed
        #expect(PostEventPrompt.nextPromptDate(for: dismissedContact, of: dismissed) == nil)

        let (neverSent, neverSentContact) = neylaShaped(ctx)
        neverSentContact.sentAt = nil
        neverSentContact.gmailMessageId = nil
        neverSentContact.sendState = .pending
        #expect(PostEventPrompt.nextPromptDate(for: neverSentContact, of: neverSent) == nil)

        let (undated, undatedContact) = neylaShaped(ctx, showDate: "")
        undated.performanceDate = nil
        #expect(PostEventPrompt.nextPromptDate(for: undatedContact, of: undated) == nil)

        let (anchored, anchoredContact) = neylaShaped(ctx)
        anchoredContact.conversationRemindedAt = day("2026-08-20")
        #expect(PostEventPrompt.nextPromptDate(for: anchoredContact, of: anchored) == nil)
    }

    // MARK: the countdown

    // The regression guard the issue specifies: it asserts the countdown NAMES the nearer moment, not
    // merely that it has one. A guard checking only for a value would have passed on the wrong date the
    // whole time this was broken (L63).
    @Test func theCountdownNamesTheCloserOfTheTwoClocks() throws {
        let ctx = try context()
        let (p, r) = neylaShaped(ctx)
        let today = day("2026-08-13")

        let nudgeDue = try #require(FollowUp.nextDue(eligible: FollowUp.isAwaitingNudge(r, in: p, now: today),
                                                    sentAt: r.sentAt, lastFollowUpAt: r.lastFollowUpAt,
                                                    followUpCount: r.followUpCount,
                                                    remindedAt: r.nudgeRemindedAt))
        let promptDue = try #require(PostEventPrompt.nextPromptDate(for: r, of: p))
        // Non-vacuity: this fixture is only a test of "nearest" while the two clocks genuinely differ and
        // the prompt is the nearer one. An invented shape that happened to agree would prove nothing (L48).
        #expect(promptDue < nudgeDue)

        let next = try #require(ReachedOutQueue.nextActionableMoment(for: r, of: p, now: today))
        #expect(next == promptDue)
        #expect(next != nudgeDue)
    }

    // And what Dan actually reads on the row: one day, not five.
    @Test func theRowReadsOneDayNotFive() throws {
        let ctx = try context()
        let (p, r) = neylaShaped(ctx)
        let label = ReachedOutQueue.timingLabel(for: r, of: p, now: day("2026-08-13"), today: "2026-08-13")
        #expect(label.contains("1 day"))
        #expect(!label.contains("5 days"))
    }

    // MARK: the siblings

    // The other clocks feeding `nextActionableMoment`, each asked the same question this issue asks: can
    // it answer nil for a moment that is merely IN THE FUTURE rather than absent? Stated as tests rather
    // than as a claim in a PR body, so the answer stays true.
    //
    // `FollowUp.nextDue` takes no clock at all, so it cannot withhold a future date. Proven by asking it
    // for one long before it arrives.
    @Test func theNudgeClockAlreadyNamesFutureDates() throws {
        let ctx = try context()
        let (p, r) = neylaShaped(ctx)
        let due = FollowUp.nextDue(eligible: FollowUp.isAwaitingNudge(r, in: p, now: day("2026-08-12")), sentAt: r.sentAt,
                                   lastFollowUpAt: r.lastFollowUpAt, followUpCount: r.followUpCount,
                                   remindedAt: r.nudgeRemindedAt)
        #expect(due != nil)
        #expect(try #require(due) > day("2026-08-13"))
    }

    // The form decision clock takes no clock either: it is the show's own night, or the pitch plus the
    // gap for an undated show. Asked from long before the night, it still names it.
    @Test func theFormDecisionClockAlreadyNamesFutureDates() throws {
        let ctx = try context()
        let (p, r) = neylaShaped(ctx)
        r.outreachChannel = .contactForm
        r.formOutreachRecordedAt = day("2026-08-11")
        let next = try #require(ReachedOutQueue.nextActionableMoment(for: r, of: p, now: day("2026-08-01")))
        #expect(next > day("2026-08-01"))
    }

    // The reply track is not a schedule at all: it dates work that has ALREADY arrived, so it has no
    // future moment it could withhold. A reply that has not arrived contributes nothing, which is absence
    // rather than silence.
    @Test func theReplyTrackHasNoFutureMomentToWithhold() throws {
        let ctx = try context()
        let (p, r) = neylaShaped(ctx)
        r.reopenOnReply(at: day("2026-08-12"))
        let next = try #require(ReachedOutQueue.nextActionableMoment(for: r, of: p, now: day("2026-08-13")))
        #expect(next <= day("2026-08-13"))   // in the past, because the reply is already sitting there
    }

    // MARK: what must NOT move

    // The row's SORT key is a different question from what is owed (#2550), and this change must not
    // disturb it. It cannot: the sort key already carries a floor at the show's own date, and the prompt
    // comes due the day AFTER, so a newly visible prompt date can never be the minimum.
    @Test func theSortKeyIsUnchangedByTheNewlyVisibleDate() throws {
        let ctx = try context()
        let (p, r) = neylaShaped(ctx)
        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: day("2026-08-13")) == day("2026-08-13"))
    }
}
