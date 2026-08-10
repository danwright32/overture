import Testing
import Foundation
import SwiftData

// #2118: the reached-out queue answers ONE question, "when does this next need Dan", and until now it
// answered it twice. A scouted show's contact went through ReachedOutQueue.nextReachOut, a direct hire
// inquiry through Inquiry.nextReachOutDate, and the two reimplemented the same idea side by side.
//
// It matters because both halves land under the SAME date headings in one list (#1513), so a rule that
// reaches only one of them produces two cards that look alike and sort differently, and nothing flags
// the divergence. #2111 fixed the show half's reply date and left the inquiry half on its own copy.
//
// These tests are written against the merged list itself (QueueModel.reachedOutEntries), because that
// is where the divergence is visible: the same reply on the two kinds of row has to land on the same
// day. An inquiry stays a fully separate entity from a prospect, never linked or merged; only the
// next-reach-out computation is shared.
@MainActor
@Suite("Inquiries and shows share one next reach-out rule (#2118)")
struct OneNextReachOutRuleTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // 2026-08-05 12:00 UTC = 08:00 EDT, the morning Dan met Nicole Becker's card in #2111.
    private var now: Date { Date(timeIntervalSince1970: 1_785_931_200) }
    // They wrote at 2026-08-04 20:56 EDT. Overture only noticed on the next launch, 2026-08-05 07:00 EDT.
    private var theyWrote: Date { Date(timeIntervalSince1970: 1_785_891_390) }
    private var overtureNoticed: Date { Date(timeIntervalSince1970: 1_785_927_600) }

    private func makeShow(_ ctx: ModelContext, replySentAt: Date?, noticedAt: Date?) -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "k", groupName: "Every Voice", discipline: "choral", venue: "V",
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        let r = Recipient(id: "nbecker@everyvoicechoirs.org", email: "nbecker@everyvoicechoirs.org",
                          name: "Nicole", provenance: .act)
        r.sentAt = now.addingTimeInterval(-6 * 86_400)
        r.sendState = .sent
        r.gmailMessageId = "msg-1"
        if let noticedAt {
            r.replied = true
            r.repliedAt = noticedAt
            r.inboundReplySentAt = replySentAt
        }
        p.recipients = [r]
        ctx.insert(p)
        return (p, r)
    }

    private func makeInquiry(_ ctx: ModelContext, replySentAt: Date?, noticedAt: Date?) -> Inquiry {
        let inq = Inquiry(source: .contactForm, inquirerName: "Ada", inquirerEmail: "ada@x.org",
                          eventName: "Gala", performanceDate: nil)
        inq.sentAt = now.addingTimeInterval(-6 * 86_400)
        inq.gmailMessageId = "msg-2"
        if let noticedAt {
            inq.replied = true
            inq.repliedAt = noticedAt
            inq.inboundReplySentAt = replySentAt
        }
        ctx.insert(inq)
        return inq
    }

    // Both rows of the merged list, keyed by kind, so a test can compare the two halves directly.
    private func dates(_ p: Prospect, _ r: Recipient, _ inq: Inquiry,
                       at clock: Date) -> (show: Date?, inquiry: Date?) {
        let showNext = ReachedOutQueue.nextReachOut(for: r, of: p, now: clock)
        let entries = QueueModel.reachedOutEntries(
            prospects: showNext.map { [(prospect: p, recipient: r, next: $0)] } ?? [],
            inquiries: [inq], now: clock)
        var show: Date?
        var inquiry: Date?
        for entry in entries {
            switch entry {
            case .prospect(_, _, let next): show = next
            case .inquiry(_, _, let next): inquiry = next
            }
        }
        return (show, inquiry)
    }

    // The divergence itself. One reply, written the evening before and noticed the next morning, on the
    // two kinds of row: the show dates it when they wrote (#2111/#2113), the inquiry dated it when
    // Overture noticed, so the two cards sat under different headings for the same event.
    @Test("both kinds date a reply by when it was written, not when Overture noticed")
    func bothKindsDateAReplyByWhenItWasWritten() throws {
        let ctx = ModelContext(try container())
        let (p, r) = makeShow(ctx, replySentAt: theyWrote, noticedAt: overtureNoticed)
        let inq = makeInquiry(ctx, replySentAt: theyWrote, noticedAt: overtureNoticed)

        let d = dates(p, r, inq, at: now)

        #expect(d.show == theyWrote)
        #expect(d.inquiry == theyWrote)
        #expect(d.show == d.inquiry, "the same reply put the two kinds of row under different headings")
        #expect(EasternDate.dayString(from: try #require(d.inquiry)) == "2026-08-04")
    }

    // L74: a date computed from the clock at read time can never age, so a missed reach-out silently
    // re-files itself under today. Held over BOTH halves at once, because a rule that reaches only one
    // of them is exactly what this issue exists to end.
    @Test("neither kind re-files itself under today as the days pass")
    func neitherKindRefilesItselfAsTheDaysPass() throws {
        let ctx = ModelContext(try container())
        let (p, r) = makeShow(ctx, replySentAt: theyWrote, noticedAt: overtureNoticed)
        let inq = makeInquiry(ctx, replySentAt: theyWrote, noticedAt: overtureNoticed)

        let today = dates(p, r, inq, at: now)
        let threeDaysOn = dates(p, r, inq, at: now.addingTimeInterval(3 * 86_400))

        #expect(today.show == threeDaysOn.show, "the show moved with the clock")
        #expect(today.inquiry == threeDaysOn.inquiry, "the inquiry moved with the clock")
        #expect(threeDaysOn.show == theyWrote)
        #expect(threeDaysOn.inquiry == theyWrote)
        // Still reads as overdue rather than as work that only just arrived.
        #expect(ReachedOutQueue.isDueNow(next: try #require(threeDaysOn.inquiry),
                                         now: now.addingTimeInterval(3 * 86_400)))
    }

    // Clock skew is not a reason to stop asking. A reply stamped ahead of the clock must still read as
    // due on both kinds of row; without the clamp the card silently leaves the due list and files itself
    // under a heading in the future until the clock catches up.
    @Test("a reply stamped in the future is still due now on both kinds")
    func aReplyStampedInTheFutureIsStillDueOnBothKinds() throws {
        let ctx = ModelContext(try container())
        let skewed = now.addingTimeInterval(2 * 86_400)
        let (p, r) = makeShow(ctx, replySentAt: skewed, noticedAt: skewed)
        let inq = makeInquiry(ctx, replySentAt: skewed, noticedAt: skewed)

        let d = dates(p, r, inq, at: now)

        #expect(d.show == now)
        #expect(d.inquiry == now)
        #expect(ReachedOutQueue.isDueNow(next: try #require(d.inquiry), now: now))
    }

    // The shared guard: nothing in play means no date at all, on either kind. A closed record must not
    // keep a reach-out date, or it goes on asking for work about something that is finished.
    @Test("neither kind has a date once it is closed")
    func neitherKindHasADateOnceClosed() throws {
        let ctx = ModelContext(try container())
        let (p, r) = makeShow(ctx, replySentAt: theyWrote, noticedAt: overtureNoticed)
        let inq = makeInquiry(ctx, replySentAt: theyWrote, noticedAt: overtureNoticed)
        p.markOutcomeManually(.booked, now: now)
        r.resolution = .booked
        inq.markOutcomeManually(.booked, now: now)

        let d = dates(p, r, inq, at: now)

        #expect(d.show == nil)
        #expect(d.inquiry == nil)
    }
}

// The shared rule on its own terms. Each side hands it the tracks its own entity has, and everything
// below is what it does with them no matter which side asked.
@Suite("The shared next reach-out rule (#2118)")
struct NextReachOutRuleTests {
    private var now: Date { Date(timeIntervalSince1970: 1_785_931_200) }

    // Nothing left to reach out about means no date at all, whatever the tracks would have said. The
    // tracks are not even built: a closed record must not pay for dates nobody will read (L62).
    @Test("out of play means no date, and no track is built")
    func outOfPlayMeansNoDate() {
        var built = false
        let date = NextReachOut.date(isInPlay: false, now: now) {
            built = true
            return [.scheduled(self.now)]
        }
        #expect(date == nil)
        #expect(!built, "an out-of-play record built its tracks anyway")
    }

    // The soonest track wins, which is what makes one date out of several answers.
    @Test("the soonest track wins")
    func soonestTrackWins() {
        let soon = now.addingTimeInterval(86_400)
        let later = now.addingTimeInterval(9 * 86_400)
        #expect(NextReachOut.date(isInPlay: true, now: now) { [.scheduled(later), .scheduled(soon)] } == soon)
    }

    // A track with nothing scheduled contributes nothing rather than standing in for the whole answer.
    @Test("a track with nothing scheduled drops out, and no tracks at all means no date")
    func emptyTracksDropOut() {
        let soon = now.addingTimeInterval(86_400)
        #expect(NextReachOut.date(isInPlay: true, now: now) { [.scheduled(nil), .scheduled(soon)] } == soon)
        #expect(NextReachOut.date(isInPlay: true, now: now) { [.scheduled(nil)] } == nil)
        #expect(NextReachOut.date(isInPlay: true, now: now) { [] } == nil)
    }

    // L74: waiting work is dated by when it arrived, so it ages. Read twice a week apart, it gives the
    // same answer both times and reads later as further overdue, not as work that just came in.
    @Test("waiting work keeps the day it arrived as the clock moves on")
    func waitingWorkKeepsItsArrivalDay() {
        let arrived = now.addingTimeInterval(-2 * 86_400)
        let aWeekOn = now.addingTimeInterval(7 * 86_400)
        #expect(NextReachOut.date(isInPlay: true, now: now) { [.waiting(since: arrived)] } == arrived)
        #expect(NextReachOut.date(isInPlay: true, now: aWeekOn) { [.waiting(since: arrived)] } == arrived)
    }

    // Clock skew is not a reason to stop asking: an arrival stamped ahead of the clock is clamped back to
    // now, so the item stays in the due list instead of filing itself under a heading in the future.
    @Test("an arrival stamped in the future is clamped back to now")
    func aFutureArrivalIsClamped() {
        let skewed = now.addingTimeInterval(2 * 86_400)
        #expect(NextReachOut.date(isInPlay: true, now: now) { [.waiting(since: skewed)] } == now)
        #expect(NextReachOut.arrived(skewed, now: now) == now)
    }

    // A record whose arrival was never recorded keeps the old reading rather than dropping out of the
    // list, which would take a live conversation off the one surface it appears on.
    @Test("waiting work with no recorded arrival falls back to now")
    func anUnrecordedArrivalFallsBackToNow() {
        #expect(NextReachOut.date(isInPlay: true, now: now) { [.waiting(since: nil)] } == now)
        #expect(NextReachOut.arrived(nil, now: now) == now)
    }

    // A scheduled track is taken as given, including a future one: it is a decision about when, not
    // evidence about when something landed, so the clamp must not touch it.
    @Test("a scheduled track is taken as given, future included")
    func aScheduledTrackIsNotClamped() {
        let nextWeek = now.addingTimeInterval(7 * 86_400)
        #expect(NextReachOut.date(isInPlay: true, now: now) { [.scheduled(nextWeek)] } == nextWeek)
    }
}

// The structural half of #2118: both entities must keep ASKING the shared rule. The behavioural tests
// above prove the two agree today; this fails the moment either side grows its own copy back, which is
// the way the divergence arrived the first time.
@Suite("Both reached-out entities are forced through the shared rule (#2118)")
struct NextReachOutIsTheOnlyRuleTests {
    @Test("the show side and the inquiry side both answer through NextReachOut")
    func bothSidesCallTheSharedRule() {
        let queue = SourceGuardHelper.source("Overture/Domain/ReachedOutQueue.swift")
        let inquiry = SourceGuardHelper.source("Overture/Domain/Inquiry.swift")

        #expect(queue.contains("NextReachOut.date(isInPlay:"),
                "a scouted contact's reach-out date stopped going through the shared rule")
        #expect(inquiry.contains("NextReachOut.date(isInPlay:"),
                "an inquiry's reach-out date stopped going through the shared rule")
    }

    // The clamp that keeps a skewed arrival in the due list has exactly one implementation, so a second
    // copy cannot drift from it the way the two reach-out rules did.
    @Test("the arrival clamp is written once")
    func theArrivalClampIsWrittenOnce() {
        let rule = SourceGuardHelper.source("Overture/Domain/NextReachOut.swift")
        #expect(rule.contains("min(arrivedAt ?? now, now)"))

        // #2397: the reach-out schedule is where the arrival case is asked now. The conversation reminder
        // that used to hold it is retired, and its post-event successor is triggered by a DATE rather than
        // by an arrival, so it has no business owning this clamp.
        let queue = SourceGuardHelper.source("Overture/Domain/ReachedOutQueue.swift")
        #expect(queue.contains(".waiting(since:"))
        #expect(!queue.contains("min(arrivedAt ?? now, now)"),
                "ReachedOutQueue grew its own copy of the arrival clamp")
        let prompt = SourceGuardHelper.source("Overture/Domain/PostEventPrompt.swift")
        #expect(!prompt.contains("min(arrivedAt ?? now, now)"),
                "PostEventPrompt grew a copy of the arrival clamp it has no use for")
    }
}
