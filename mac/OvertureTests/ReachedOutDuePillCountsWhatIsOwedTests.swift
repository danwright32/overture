import Testing
import Foundation
import SwiftData

// #2802: the Reached out pill counted its due rows by the SORT key while the rows themselves read what is
// actually OWED, so the masthead read "Reached out  1 due" in gold over a list where nothing was due and
// nothing was painted rust.
//
// The two dates are deliberately different, and neither is wrong:
//
//   - `ReachedOutQueue.nextReachOut` is the sort key. It folds in #2397's FLOOR, which pins an open pitch
//     to the show's own night so a live pitch can never fall off the stage (L45). It asserts nothing about
//     anything being due.
//   - `ReachedOutQueue.nextActionableMoment` is what is OWED (a nudge, a form decision, the post-event
//     prompt, an unanswered reply). The floor is excluded on purpose.
//
// #2550 moved the ROW onto the second one, through `ReachedOutQueue.isDueNow(for:of:now:)`, and left the
// pill on the first. So every pitched show counted as due on its own night, which is every night a pitched
// show performs, and the comment above the count still said the two could not disagree (L16, L32).
//
// Dan, 2026-08-16: the masthead read `Reached out  1 due` over Heather Curran "in 1 day", 54 Sings "in 2
// days", First Drafts "in 3 days", Pumpkin Singalong "in 71 days". He asked why.
//
// These tests pin the COUNT against the same question the row is asked. Both ends are pinned literals (the
// fixture dates and the clock), never a bare `Date()`: the whole meaning of this fixture is the
// relationship between the show's date and today, and a live clock walks that into a different case (L130).
@MainActor
@Suite("The Reached out due count reads what is owed (#2802)")
struct ReachedOutDuePillCountsWhatIsOwedTests {
    // The day Dan read the masthead, and mid afternoon on it, so the show's own Eastern midnight (the
    // floor) is already past while the morning after (the post-event prompt) is not.
    private let today = "2026-08-16"
    private var now: Date { EasternDate.date(from: "2026-08-16")!.addingTimeInterval(15 * 3_600) }

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ key: String, day: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Merkin Hall",
                         performanceDate: day, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        ctx.insert(p)
        return p
    }

    // A contact genuinely pitched: sent, with an address and the Gmail message id a real send stamps,
    // which is what `hasProvenOutreach` demands.
    @discardableResult
    private func pitched(_ ctx: ModelContext, on p: Prospect, id: String, sentOn day: String) -> Recipient {
        let r = Recipient(id: id, email: id, provenance: .act)
        r.sentAt = EasternDate.date(from: day)!
        r.sendState = .sent
        r.gmailMessageId = "msg-\(id)"
        p.setRecipients(p.recipients + [r])
        ctx.insert(r)
        return r
    }

    private func inputs(_ all: [Prospect]) -> AgentInputs {
        AgentInputs.from(prospects: all, allProspects: all, context: .at(today, now: now),
                         gmailConnected: true, runInFlight: nil, replyRunAlive: false)
    }

    // Heather Curran's row. The show performs tonight, so the floor is this morning's Eastern midnight and
    // the sort key already reads as due; what is actually owed is tomorrow morning's close-out prompt. The
    // row says "in 1 day" and stays quiet, so the pill must be silent too.
    @Test func aShowPerformingTonightWithNothingOwedIsNotCountedAsDue() throws {
        let ctx = try context()
        let p = show(ctx, "Heather Curran", day: "2026-08-16")
        let r = pitched(ctx, on: p, id: "heather@example.org", sentOn: "2026-08-15")
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        // The row is on the stage, held there by the floor, and the SORT key reads due now...
        #expect(ReachedOutQueue.activeWithDates(from: all, now: now).count == 1)
        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: now) == EasternDate.date(from: "2026-08-16"))
        #expect(ReachedOutQueue.isDueNow(next: ReachedOutQueue.nextReachOut(for: r, of: p, now: now)!, now: now))
        // ...while nothing is OWED, which is what the row paints its urgency from.
        #expect(!ReachedOutQueue.isDueNow(for: r, of: p, now: now))
        #expect(ReachedOutQueue.timingLabel(for: r, of: p, now: now, today: today) == "in 1 day")

        // So the pill says nothing, because the list it heads says nothing.
        #expect(inputs(all).reachedOutDue == 0)
    }

    // And it still counts what IS owed: a pitch whose second nudge has come due is due on the row and due
    // on the pill. A count that only ever reads zero is not a fix, it is a different defect.
    @Test func aShowOwedANudgeIsStillCounted() throws {
        let ctx = try context()
        let p = show(ctx, "First Drafts", day: "2026-09-30")
        let r = pitched(ctx, on: p, id: "first@example.org", sentOn: "2026-08-06")
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        #expect(ReachedOutQueue.isDueNow(for: r, of: p, now: now))
        #expect(inputs(all).reachedOutDue == 1)
    }

    // The reading Dan met: both shows on the stage at once. The pill counted two and the list painted one,
    // and this is the exact arithmetic that put a gold "1 due" over four quiet rows.
    @Test func onlyTheOwedShowIsCountedWhenBothAreOnTheStage() throws {
        let ctx = try context()
        let tonight = show(ctx, "Heather Curran", day: "2026-08-16")
        pitched(ctx, on: tonight, id: "heather@example.org", sentOn: "2026-08-15")
        let owed = show(ctx, "First Drafts", day: "2026-09-30")
        pitched(ctx, on: owed, id: "first@example.org", sentOn: "2026-08-06")
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        #expect(inputs(all).reachedOut == 2)        // both rows are on the stage
        #expect(inputs(all).reachedOutDue == 1)     // and exactly one of them is owed anything
    }

    // The show-level fold, stated rather than left implicit. `activeWithDates` returns one row per SHOW
    // with a representative contact ("whoever replied, else the contact due soonest by the sort key"), and
    // the ROW paints its urgency from that representative. So the pill asks the representative too: a pill
    // that counted a colleague the row is not speaking for would land Dan on a row that disagrees with it,
    // which is the whole defect over again in the other direction (#863).
    @Test func theCountAsksTheSameContactTheRowSpeaksFor() throws {
        let ctx = try context()
        let p = show(ctx, "Heather Curran", day: "2026-08-16")
        let quiet = pitched(ctx, on: p, id: "heather@example.org", sentOn: "2026-08-15")
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let rows = ReachedOutQueue.activeWithDates(from: all, now: now)
        #expect(rows.count == 1)
        #expect(rows.first?.recipient.id == quiet.id)
        // One row, its representative owes nothing, so the number over it is nothing.
        #expect(inputs(all).reachedOutDue == 0)
    }

    // The inquiry half of the same count is a different rule and is unchanged: an inquiry that has replied
    // is due by definition, because somebody is waiting on an answer. Pinned here so a change to the
    // prospect side cannot quietly take the inquiry side with it.
    @Test func aRepliedInquiryIsStillDueByDefinition() throws {
        let inquiry = Inquiry(source: .directEmail, inquirerName: "Ada", inquirerEmail: "ada@example.org",
                              eventName: "Gala", performanceDate: "2026-09-30")
        inquiry.sentAt = EasternDate.date(from: "2026-08-14")   // replied to once, so it sits in Reached out
        inquiry.replied = true                                   // and they wrote back, so somebody is waiting
        #expect(StageNavigation.stage(for: inquiry) == .reachedOut)

        let built = AgentInputs.from(prospects: [], allProspects: [], inquiries: [inquiry], context: .at(today, now: now),
                                     gmailConnected: true, runInFlight: nil, replyRunAlive: false)
        #expect(built.reachedOutDue == 1)
    }
}
