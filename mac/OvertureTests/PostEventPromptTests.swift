import Testing
import Foundation
import SwiftData

// #2397, phase 4 of docs/plans/2026-08-09-one-outcome-vocabulary.md.
//
// `ConversationState` is retired, and with it the whole cadence keyed on it: the three interval settings,
// the two-day "you haven't said where this stands" chase, the AI's guess at the state, and the Confirm
// button beside it. Dan, on the state menu: "we shouldn't have both state and close out. It feels like it's
// supposed to be the same thing? state is mostly just trying to capture the outcome." Asked whether the
// three live values earned their place given they only tuned nudge timing and nudge wording, he chose to
// drop all three.
//
// What survives is the POST-EVENT prompt, because its trigger is the show's DATE rather than anything Dan
// sets, so it never depended on the state in the first place. It has two kinds, and which one appears turns
// on one question: did anybody write back?
@MainActor
@Suite("The post-event prompt (#2397)")
struct PostEventPromptTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    // A show on 2026-03-01, pitched a month before it.
    private func show(_ ctx: ModelContext, date: String = "2026-03-01") -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music", venue: "V",
                         performanceDate: date, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.sentAt = day("2026-02-01")
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ ctx: ModelContext, on p: Prospect, replied: Bool = false) -> Recipient {
        let r = Recipient(id: "a@b.com", email: "a@b.com", provenance: .manual)
        r.sendState = .sent
        r.sentAt = day("2026-02-01")
        r.gmailMessageId = "m1"
        if replied { r.reopenOnReply(at: day("2026-02-05")) }
        r.prospect = p
        ctx.insert(r)
        return r
    }

    private func day(_ s: String) -> Date { EasternDate.date(from: s)! }

    // MARK: nothing is due before the event

    // The cadence is gone. A live conversation raises nothing at all until its show has been and gone,
    // which is the whole of what Dan asked for: the three states only ever tuned nudge timing and nudge
    // wording, and he chose to drop them rather than keep tuning.
    @Test func alivePitchRaisesNothingBeforeTheShow() throws {
        let ctx = try context()
        let p = show(ctx)
        contact(ctx, on: p)

        #expect(PostEventPrompt.dueRecipients(from: [p], now: day("2026-02-20")).isEmpty)
    }

    @Test func areplyBeforeTheShowRaisesNothingEither() throws {
        let ctx = try context()
        let p = show(ctx)
        contact(ctx, on: p, replied: true)

        // Answering a reply is its own work, on its own surface. It is deliberately NOT a reminder any
        // more: the two-day "you haven't said where this stands" chase went with the states it chased.
        #expect(PostEventPrompt.dueRecipients(from: [p], now: day("2026-02-20")).isEmpty)
    }

    // MARK: after the event, two kinds

    // Nobody wrote back, so the gracious closing note is what fits, and Dan's rule for it is exact: "If
    // I'm sending that, it basically HAS to mean never heard back."
    @Test func nobodyRepliedSoTheClosingNoteIsOffered() throws {
        let ctx = try context()
        let p = show(ctx)
        contact(ctx, on: p)

        let due = PostEventPrompt.dueRecipients(from: [p], now: day("2026-03-05"))

        #expect(due.count == 1)
        #expect(due.first?.prompt.kind == .closeOutUnanswered)
    }

    // Somebody DID write back and no ending was recorded. The closing note would assert nobody answered,
    // which is false, so the prompt is to close it out instead: Dan already knows what happened, it only
    // needs recording. His decision, 2026-08-09, asked directly.
    @Test func theyRepliedSoDanIsAskedToCloseItOut() throws {
        let ctx = try context()
        let p = show(ctx)
        contact(ctx, on: p, replied: true)

        let due = PostEventPrompt.dueRecipients(from: [p], now: day("2026-03-05"))

        #expect(due.count == 1)
        #expect(due.first?.prompt.kind == .closeOut)
    }

    // The prompt is dated the day AFTER the show, not read off the clock, so one owed for a week reads a
    // week overdue rather than arriving fresh every morning (#2116's rule, kept).
    @Test func thepromptIsDatedTheDayAfterTheShow() throws {
        let ctx = try context()
        let p = show(ctx)
        let r = contact(ctx, on: p)

        // #2646: it takes no clock now, and names its date whether or not that date has arrived. Asked
        // from BEFORE the show as well as after, so this pins the dating rule rather than the old
        // silence.
        #expect(PostEventPrompt.nextPromptDate(for: r, of: p) == day("2026-03-02"))
    }

    // On the show's own day it has not been and gone. A run opening tonight has not opened yet.
    @Test func nothingIsDueOnTheShowsOwnDay() throws {
        let ctx = try context()
        let p = show(ctx)
        contact(ctx, on: p)

        #expect(PostEventPrompt.dueRecipients(from: [p], now: day("2026-03-01")).isEmpty)
    }

    // An undated show never has a date to pass, and "date to be confirmed" is a normal state on a season
    // page, so it must not raise a prompt on the strength of a date nobody knows.
    @Test func anundatedShowRaisesNothing() throws {
        let ctx = try context()
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: nil, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.sentAt = day("2026-02-01")
        ctx.insert(p)
        contact(ctx, on: p)

        #expect(PostEventPrompt.dueRecipients(from: [p], now: day("2026-03-05")).isEmpty)
    }

    // MARK: an ending stops it

    // Once Dan has closed a show out, Overture stops asking about it. The inverse of his own rule that
    // nothing is closed unless he closed it: once he has, leave it alone.
    @Test func ashowCarryingAnEndingRaisesNoPrompt() throws {
        let ctx = try context()
        for ending in ShowOutcome.pitched {
            let ctx2 = try context()
            let p = show(ctx2)
            contact(ctx2, on: p)
            p.showOutcome = ending

            #expect(PostEventPrompt.dueRecipients(from: [p], now: day("2026-03-05")).isEmpty,
                    "\(ending.label) still raised a prompt")
        }
        _ = ctx
    }

    // A dismissed show stops nagging (#238), unchanged.
    @Test func adismissedShowRaisesNoPrompt() throws {
        let ctx = try context()
        let p = show(ctx)
        contact(ctx, on: p)
        p.markDismissed(reason: .notAFit)

        #expect(PostEventPrompt.dueRecipients(from: [p], now: day("2026-03-05")).isEmpty)
    }

    // MARK: what each kind is

    // #2710: everything between here and the next test was about the closing note as an EMAIL: that only
    // it had a sendable body, and what that body said about a show having come and gone. The email is
    // gone, so there is nothing to compose and nothing to say. `NoClosingNoteAfterTheShowTests` holds what
    // replaced it, and the two kinds below are now both requests to record an ending.

    // Each kind says what it is, and the two must not read the same, because they ask for different
    // things: one sends an email, the other records a decision.
    @Test func thetwoKindsReadDifferently() {
        let a = PostEventPrompt.reason(for: .closeOutUnanswered)
        let b = PostEventPrompt.reason(for: .closeOut)
        #expect(!a.isEmpty)
        #expect(!b.isEmpty)
        #expect(a != b)
    }
}
