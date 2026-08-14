import Testing
import Foundation
import SwiftData

// #2651: a cold contact who never replies could receive three messages, and the last two both said
// goodbye.
//
//   1. follow-up 1
//   2. follow-up 2, the final one, which ends "If it would be useful down the line I'm glad to help,
//      and if not, no need to reply. I'll leave it here either way."
//   3. the closing note, once the show date passes, which says a very similar thing again.
//
// Message 2 has already closed the conversation in Dan's voice. Message 3 then reopens it to close it a
// second time, and to a stranger who has ignored two emails that reads as a third unsolicited contact
// rather than as grace. The scheduling makes it ordinary rather than exotic: follow-ups are paced by
// `gapDays` up to `maxFollowUps`, and the closing note fires the day after the show, so any lead scouted
// far enough ahead exhausts its follow-ups well before the date arrives.
//
// THE DECISION, since the issue says either is defensible and both is not. The closing note is
// SUPPRESSED for a contact who has already had the final follow-up, rather than the final follow-up
// being made to stop saying goodbye. Three reasons:
//
//   - the final follow-up's goodbye has already been SENT to everybody currently at two nudges. Rewording
//     it helps only future contacts and leaves every existing one still getting two goodbyes;
//   - the `.closingNote` branch is by construction the never-replied case (a show anybody replied to gets
//     `.closeOut`, which is Dan recording a decision, not an email), so it is exactly the case where the
//     goodbye has already been said;
//   - to a stranger who has ignored two emails, a third is worse than nothing.
//
// The rule lives in `nextPromptDate`, which the issue names as the right home because it is already the
// single source of truth for whether a post-event prompt is owed.
@MainActor
@Suite("One goodbye per contact (#2651)")
struct OneGoodbyePerContactTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func day(_ s: String) -> Date { EasternDate.date(from: s)! }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music", venue: "V",
                         performanceDate: "2026-03-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.sentAt = day("2026-02-01")
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ ctx: ModelContext, on p: Prospect, nudges: Int,
                         replied: Bool = false, id: String = "a@b.com") -> Recipient {
        let r = Recipient(id: id, email: id, provenance: .manual)
        r.sendState = .sent
        r.sentAt = day("2026-02-01")
        r.gmailMessageId = "m1"
        r.followUpCount = nudges
        if replied { r.reopenOnReply(at: day("2026-02-05")) }
        r.prospect = p
        ctx.insert(r)
        return r
    }

    private let afterTheShow = "2026-03-02"

    // MARK: - The defect

    // Two nudges gone means the goodbye has gone. Nothing further is owed, and `nextPromptDate` says so
    // by naming no date at all rather than a date in the past.
    @Test func aContactWhoHasHadTheFinalNudgeIsOwedNoClosingNote() throws {
        let ctx = try context()
        let p = show(ctx)
        let r = contact(ctx, on: p, nudges: FollowUpConfig().maxFollowUps)

        #expect(PostEventPrompt.nextPromptDate(for: r, of: p) == nil)
        #expect(PostEventPrompt.prompt(for: r, of: p, now: day(afterTheShow)) == nil)
    }

    // MARK: - What must still happen

    // One nudge is not the last one, so its goodbye has not been said and the closing note is still the
    // grace it was written to be.
    @Test func aContactPartWayThroughItsNudgesStillGetsTheClosingNote() throws {
        let ctx = try context()
        let p = show(ctx)
        let r = contact(ctx, on: p, nudges: 1)

        #expect(PostEventPrompt.nextPromptDate(for: r, of: p) == day("2026-03-02"))
        #expect(PostEventPrompt.prompt(for: r, of: p, now: day(afterTheShow))?.kind == .closingNote)
    }

    @Test func aContactWithNoNudgesAtAllStillGetsTheClosingNote() throws {
        let ctx = try context()
        let p = show(ctx)
        let r = contact(ctx, on: p, nudges: 0)

        #expect(PostEventPrompt.prompt(for: r, of: p, now: day(afterTheShow))?.kind == .closingNote)
    }

    // The half this must not break, and the reason the rule cannot simply be "two nudges, nothing more".
    // A close-out is not an email at all: it is Dan recording how the show ended, it is the more useful of
    // the two prompts to him, and it is a fact only he has. Suppressing it because Overture happened to
    // send two nudges would lose the outcome the whole funnel is reported on.
    @Test func aShowSomebodyRepliedToStillAsksDanToCloseItOut() throws {
        let ctx = try context()
        let p = show(ctx)
        let r = contact(ctx, on: p, nudges: FollowUpConfig().maxFollowUps, replied: true)

        #expect(PostEventPrompt.nextPromptDate(for: r, of: p) == day("2026-03-02"))
        #expect(PostEventPrompt.prompt(for: r, of: p, now: day(afterTheShow))?.kind == .closeOut)
    }

    // A reply from ANYBODY on the show is an answer about the event, which is the rule `prompt` already
    // follows in choosing the kind. So a colleague's reply keeps the close-out owed even on the contact
    // who was nudged twice and never answered himself.
    @Test func aColleaguesReplyKeepsTheCloseOutOwedOnTheSilentContact() throws {
        let ctx = try context()
        let p = show(ctx)
        let silent = contact(ctx, on: p, nudges: FollowUpConfig().maxFollowUps, id: "silent@b.com")
        contact(ctx, on: p, nudges: 0, replied: true, id: "spoke@b.com")

        #expect(PostEventPrompt.prompt(for: silent, of: p, now: day(afterTheShow))?.kind == .closeOut)
    }

    // MARK: - The two questions stay apart

    // #2646 split "when is this due" from "is it due yet", and this rule belongs to the first. A contact
    // whose closing note is suppressed must report NO date rather than a date that has passed, or
    // `ReachedOutQueue.nextActionableMoment`'s `min` would count a suppressed prompt as the soonest thing
    // owed and the row would read as overdue for something that is never coming (L125).
    @Test func aSuppressedNoteNamesNoDateRatherThanAPastOne() throws {
        let ctx = try context()
        let p = show(ctx)
        let r = contact(ctx, on: p, nudges: FollowUpConfig().maxFollowUps)

        #expect(PostEventPrompt.nextPromptDate(for: r, of: p) == nil)
        // And it says so BEFORE the show as well as after, since the suppression is a fact about the
        // nudges rather than about the clock.
        #expect(PostEventPrompt.prompt(for: r, of: p, now: day("2026-02-20")) == nil)
    }

    // MARK: - Nobody gets two goodbyes

    // The whole issue, stated as one assertion over the sequence a cold contact actually receives: the
    // final nudge says goodbye, and after it nothing else does.
    @Test func theSequenceACodeContactReceivesEndsExactlyOnce() throws {
        let ctx = try context()
        let p = show(ctx)
        let r = contact(ctx, on: p, nudges: 1)

        // The next nudge IS the final one, and it is the one that says goodbye.
        let finalNudge = FollowUp.nudgeBody(contactName: nil, groupName: "Aurora Strings", venue: "V",
                                            attempt: FollowUp.attempt(after: r.followUpCount))
        #expect(finalNudge.contains("no need to reply"))

        // Once it has gone, nothing further is owed.
        r.followUpCount = FollowUpConfig().maxFollowUps
        #expect(PostEventPrompt.prompt(for: r, of: p, now: day(afterTheShow)) == nil)
    }
}
