import Testing
import Foundation
import SwiftData

// #2398, phase 5 of docs/plans/2026-08-09-one-outcome-vocabulary.md.
//
// Dan's rule has two halves. Nothing is closed unless he closed it: "Assume it's not closed lost if I
// haven't set a state that says it's closed." And the emails stay capped where they are: "Two nudges and
// then stop until the date of the show. Maybe add a flag that tells me I've emailed them three times
// already so no more nudges."
//
// So the show STAYS on the stage, and has to say why nothing is due. Without that a spent row looks
// identical to one nobody got round to, which is the same class of defect as #2388: two different states
// rendering as one sentence.
@MainActor
@Suite("A pitch that has spent its nudges (#2398)")
struct SpentItsNudgesTests {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)   // 2026-05-28

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    // A show still AHEAD, so the post-event prompt is not what is being measured.
    private func show(_ ctx: ModelContext, date: String = "2026-09-01") -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music", venue: "V",
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.sentAt = now.addingTimeInterval(-60 * 86_400)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ ctx: ModelContext, on p: Prospect, email: String = "a@b.com",
                         nudgesSent: Int = 0) -> Recipient {
        let r = Recipient(id: email, email: email, provenance: .manual)
        r.sendState = .sent
        r.sentAt = p.sentAt
        r.gmailMessageId = "m-\(email)"
        r.followUpCount = nudgesSent
        if nudgesSent > 0 { r.lastFollowUpAt = now.addingTimeInterval(-7 * 86_400) }
        r.prospect = p
        ctx.insert(r)
        return r
    }

    // MARK: the cap itself is unchanged

    // The pitch plus two follow-ups, exactly as it was. Dan chose to keep the number and add the marker,
    // not to change how many emails go out.
    @Test func thecapIsStillThePitchPlusTwo() {
        #expect(FollowUpConfig().maxFollowUps == 2)
    }

    @Test func anudgeIsStillDueBeforeTheCapIsReached() throws {
        let ctx = try context()
        let p = show(ctx)
        contact(ctx, on: p, nudgesSent: 1)

        #expect(!FollowUp.dueRecipients(from: [p], now: now).isEmpty)
    }

    // MARK: spent, and saying so

    @Test func acontactWithBothNudgesSentIsSpent() throws {
        let ctx = try context()
        let p = show(ctx)
        let r = contact(ctx, on: p, nudgesSent: 2)

        #expect(SpentNudges.isSpent(r))
        #expect(FollowUp.dueRecipients(from: [p], now: now).isEmpty, "no third nudge")
    }

    @Test func acontactStillUnderTheCapIsNotSpent() throws {
        let ctx = try context()
        let p = show(ctx)
        #expect(!SpentNudges.isSpent(contact(ctx, on: p, nudgesSent: 0)))
        #expect(!SpentNudges.isSpent(contact(ctx, on: p, email: "b@b.com", nudgesSent: 1)))
    }

    // The SHOW is spent when every contact that was emailed is, because a colleague with a nudge left is
    // a show that has something left to send.
    @Test func theshowIsSpentOnlyWhenEveryEmailedContactIs() throws {
        let ctx = try context()
        let p = show(ctx)
        contact(ctx, on: p, email: "spent@b.com", nudgesSent: 2)
        let fresh = contact(ctx, on: p, email: "fresh@b.com", nudgesSent: 0)

        #expect(!SpentNudges.isSpent(show: p))

        fresh.followUpCount = 2

        #expect(SpentNudges.isSpent(show: p))
    }

    // A show nothing was sent to is not "spent". It has sent nothing, which is a different state and must
    // not borrow this one's words.
    @Test func ashowNothingWasSentToIsNotSpent() throws {
        let ctx = try context()
        let p = show(ctx)
        p.sentAt = nil
        #expect(!SpentNudges.isSpent(show: p))
    }

    // MARK: what Dan reads

    // THE point of the phase. The row stays, so it has to say why nothing is due, or it reads exactly like
    // a show nobody has got round to.
    @Test func thespentRowSaysTheEmailsAreDoneAndWhatHappensNext() throws {
        let line = try #require(SpentNudges.marker(eventDay: "2026-09-01", today: "2026-05-28"))
        #expect(line.contains("3"), "it has to name how many emails went, which is Dan's own ask")
        #expect(!line.isEmpty)
    }

    // It says what happens NEXT, not just that something stopped. A line that only said "no more nudges"
    // would leave Dan wondering whether the show had been dropped.
    @Test func themarkerNamesWhenOvertureComesBack() throws {
        let line = try #require(SpentNudges.marker(eventDay: "2026-09-01", today: "2026-05-28"))
        #expect(line.lowercased().contains("show"))
    }

    // An undated show has no date to go quiet until, so the marker must not invent one. "Date to be
    // confirmed" is a normal state on a season page.
    @Test func anundatedShowGetsAmarkerThatPromisesNoDate() throws {
        let line = try #require(SpentNudges.marker(eventDay: nil, today: "2026-05-28"))
        #expect(line.contains("3"))
        #expect(!line.contains("until the show"), "there is no date to come back on")
    }

    // A spent row and a row with a nudge still to send must never read the same, which is the whole
    // defect: two different states rendering as one sentence (#2388's class).
    @Test func aspentRowNeverReadsLikeOneWithNudgesLeft() throws {
        let spent = try #require(SpentNudges.marker(eventDay: "2026-09-01", today: "2026-05-28"))
        let counting = ReachedOutQueue.timingLabel(next: now.addingTimeInterval(3 * 86_400), now: now)
        #expect(spent != counting)
    }
}
