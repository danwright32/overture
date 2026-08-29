import Testing
import Foundation
import SwiftData

// #2718: the pass that ties the three halves together on the reconcile tick. It reads the mailbox
// (#2713), ranks what it found against each in-scope contact (#2714), and stores at most one question
// per contact (#2718).
//
// This is where #2713's candidates and #2714's verdict finally get a reader in the shipping runtime.
// Until it existed, both were correct and unreachable, which is L3: built is not wired, and wired is
// not proven.
@MainActor
@Suite("The tick that proposes a conversation (#2718)")
struct ReplyProposalSweepTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                        RefusedContactAddress.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let me = "dan@danwrightphotography.com"
    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let route = "https://www.corinhale.example/contact"

    private func show(_ ctx: ModelContext, key: String = "k") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "54 Sings Shuffle Along", discipline: "music",
                         venue: "54 Below", performanceDate: "2026-09-01", sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func formPitch(_ ctx: ModelContext, on p: Prospect) -> Recipient {
        let r = Recipient(id: "form:\(route)", email: nil, name: "Corin Hale", provenance: .act)
        r.contactFormURL = route
        r.formOutreachURL = route
        r.outreachChannel = .contactForm
        r.formOutreachRecordedAt = now.addingTimeInterval(-3 * 86_400)
        r.sentAt = now.addingTimeInterval(-3 * 86_400)
        r.sendState = .sent
        p.addRecipient(r)
        return r
    }

    private func message(_ id: String, from: String, subject: String,
                         listUnsubscribe: String? = nil) -> GmailReplySearch.InboundMessage {
        GmailReplySearch.InboundMessage(messageId: id, threadId: "t-\(id)",
                                        fromAddress: ReplyDetection.email(from: from),
                                        fromName: ReplyDetection.displayName(from: from),
                                        subject: subject, sentAt: now.addingTimeInterval(-3600),
                                        listUnsubscribe: listUnsubscribe)
    }

    @Test("a message that looks like them becomes a stored question on the row")
    func aMatchBecomesAQuestion() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        let found = [message("m1", from: "Corin Hale <corin.hale@example.com>", subject: "Re: the show")]

        let outcome = await ReplyProposalSweep(fromEmail: me)
            .run(in: ctx, now: now, search: { .searched(candidates: found, searchedThrough: now,
                                                        saveFailed: false) })

        #expect(outcome == .swept(proposed: 1, attached: 0, saveFailed: false))
        #expect(ProposedConversation.stored(on: r)?.messageId == "m1")
    }

    // The refusals #2714 exists for have to survive the wiring, or they are a rule nothing applies.
    @Test("a newsletter found in the same window becomes no question at all")
    func aNewsletterBecomesNoQuestion() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        let found = [message("m1", from: "54 Below <hello@54below.com>", subject: "This week at 54 Below",
                             listUnsubscribe: "<https://54below.com/u>")]

        let outcome = await ReplyProposalSweep(fromEmail: me)
            .run(in: ctx, now: now, search: { .searched(candidates: found, searchedThrough: now,
                                                        saveFailed: false) })

        #expect(outcome == .swept(proposed: 0, attached: 0, saveFailed: false))
        #expect(ProposedConversation.stored(on: r) == nil)
    }

    // Nothing found is reachable from exactly one outcome, all the way through. A tick that could not
    // read Gmail must never leave the row looking like one where nobody wrote (L10, L11, L98).
    @Test("a failed read is reported as a failure, not as nothing found")
    func aFailedReadIsAFailure() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        formPitch(ctx, on: p)

        let outcome = await ReplyProposalSweep(fromEmail: me)
            .run(in: ctx, now: now, search: { .failed(reason: "Gmail said 401.") })

        #expect(outcome == .failed(reason: "Gmail said 401."))
    }

    @Test("a tick with nothing in scope is not a tick that found nothing")
    func nothingInScopeIsItsOwnOutcome() async throws {
        let ctx = ModelContext(try container())
        show(ctx)

        let outcome = await ReplyProposalSweep(fromEmail: me)
            .run(in: ctx, now: now, search: { .nothingInScope })

        #expect(outcome == .nothingInScope)
    }

    @Test("Gmail not being connected is its own outcome")
    func notConnectedIsItsOwnOutcome() async throws {
        let ctx = ModelContext(try container())
        show(ctx)

        let outcome = await ReplyProposalSweep(fromEmail: me)
            .run(in: ctx, now: now, search: { .notConnected })

        #expect(outcome == .notConnected)
    }

    // A question is a claim about the STORE, so it is only true once the write commits (L12).
    @Test("a sweep that cannot save says so")
    func aSweepThatCannotSaveSaysSo() async throws {
        struct Nope: Error {}
        let ctx = ModelContext(try container())
        let p = show(ctx)
        formPitch(ctx, on: p)
        let found = [message("m1", from: "Corin Hale <corin.hale@example.com>", subject: "Re: the show")]

        let outcome = await ReplyProposalSweep(fromEmail: me)
            .run(in: ctx, now: now, save: { throw Nope() },
                 search: { .searched(candidates: found, searchedThrough: now, saveFailed: false) })

        #expect(outcome == .swept(proposed: 1, attached: 0, saveFailed: true))
    }

    // The search's OWN save failure (the searched stamps, #2713) must not be lost just because the
    // proposal half saved fine: both mean "this tick could not record what it did".
    @Test("the search's own save failure is carried through")
    func theSearchesSaveFailureIsCarried() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        formPitch(ctx, on: p)

        let outcome = await ReplyProposalSweep(fromEmail: me)
            .run(in: ctx, now: now, search: { .searched(candidates: [], searchedThrough: now,
                                                        saveFailed: true) })

        #expect(outcome == .swept(proposed: 0, attached: 0, saveFailed: true))
    }

    // The tick runs every thirty minutes for as long as a pitch is open, so a question already standing
    // must not be re-asked, re-stamped, or replaced.
    @Test("a second tick does not disturb a question already standing")
    func aSecondTickLeavesTheQuestionAlone() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        let sweep = ReplyProposalSweep(fromEmail: me)
        let found = [message("m1", from: "Corin Hale <corin.hale@example.com>", subject: "Re: the show")]
        _ = await sweep.run(in: ctx, now: now,
                            search: { .searched(candidates: found, searchedThrough: now, saveFailed: false) })

        let second = await sweep.run(in: ctx, now: now.addingTimeInterval(1800),
                                     search: { .searched(candidates: found, searchedThrough: now,
                                                         saveFailed: false) })

        #expect(second == .swept(proposed: 0, attached: 0, saveFailed: false), "nothing new was proposed")
        #expect(r.replyProposedAt == now, "the standing question was not re-stamped")
    }

    // A conversation Dan has declined must never come back, which is the whole reason the decline is
    // keyed on the thread and stored as a set.
    @Test("a declined conversation is not proposed again on the next tick")
    func aDeclinedConversationDoesNotComeBack() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        let sweep = ReplyProposalSweep(fromEmail: me)
        let found = [message("m1", from: "Corin Hale <corin.hale@example.com>", subject: "Re: the show")]
        _ = await sweep.run(in: ctx, now: now,
                            search: { .searched(candidates: found, searchedThrough: now, saveFailed: false) })
        ProposedConversation.decline(on: r)

        _ = await sweep.run(in: ctx, now: now.addingTimeInterval(1800),
                            search: { .searched(candidates: found, searchedThrough: now, saveFailed: false) })

        #expect(ProposedConversation.stored(on: r) == nil)
    }
}
