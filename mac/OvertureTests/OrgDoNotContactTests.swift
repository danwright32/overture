import Testing
import Foundation
import SwiftData

// #769: an org replies "please stop emailing us", and nothing in the app remembers it. The refusal is
// filed against ONE performance and forgotten. The scout re-reads Carnegie's calendar every day, so
// when that org presents there again next season it surfaces as a fresh prospect with no memory of
// the refusal, and nothing stands between that and Dan pitching them a second time.
//
// Repeatedly emailing someone who explicitly asked you to stop is how a photographer's name gets a
// reputation in a small community. The blast radius is out of all proportion to the size of the fix,
// and it is the one mistake in this app that cannot be taken back once the email is gone.
//
// Deliberately NOT a new org entity. The do-not-contact machinery already exists: HistoryMatch
// suppresses any org carrying a "dnc" history record, and LocalHistory derives history from Dan's own
// prospects. Marking an org just has to emit that record, and the suppression path that already works
// does the rest. Inventing a parallel mechanism would have meant a second thing to get wrong.
@MainActor
@Suite("Org do-not-contact (#769)")
struct OrgDoNotContactTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func make(_ ctx: ModelContext, group: String, date: String = "2026-09-12",
                      venue: String = "Weill Recital Hall",
                      status: ReviewStatus = .queued, sentAt: Date? = nil) -> Prospect {
        let p = Prospect(naturalKey: "\(group)|\(date)", groupName: group, discipline: "music",
                         venue: venue, performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        p.sentAt = sentAt
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func all(_ ctx: ModelContext) throws -> [Prospect] {
        try ctx.fetch(FetchDescriptor<Prospect>())
    }

    // MARK: - The refusal becomes a do-not-contact the scout already knows how to honor

    @Test func aMarkedOrgBecomesADoNotContactHistoryRecord() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Refused Chorale")
        OrgDoNotContact.mark(orgOf: p, in: try all(ctx))

        let records = LocalHistory.records(from: try all(ctx))

        #expect(records.contains { $0.groupName == "Refused Chorale" && $0.status == "dnc" })
    }

    // THE test. Next season the same org presents again, and the scout must not surface it at all.
    @Test func aRefusedOrgNeverResurfacesInALaterScout() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Refused Chorale")
        OrgDoNotContact.mark(orgOf: p, in: try all(ctx))
        let history = LocalHistory.records(from: try all(ctx))

        let nextSeason = ExtractedEvent(title: "Refused Chorale", presenter: "Refused Chorale",
                                        venue: "Weill Recital Hall", performanceDate: "2027-09-11",
                                        sourceUrl: "https://example.com/next")
        let outcome = ScoutService.apply(events: [nextSeason], clients: [], history: history,
                                         blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        #expect(outcome.skipped == 1)
        #expect(try all(ctx).allSatisfy { $0.performanceDate != "2027-09-11" })
    }

    @Test func anUnrelatedOrgIsCompletelyUnaffected() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Refused Chorale")
        OrgDoNotContact.mark(orgOf: p, in: try all(ctx))
        let history = LocalHistory.records(from: try all(ctx))

        let other = ExtractedEvent(title: "Innocent Ensemble", presenter: "Innocent Ensemble",
                                   venue: "Weill Recital Hall", performanceDate: "2027-09-11",
                                   sourceUrl: "https://example.com/other")
        _ = ScoutService.apply(events: [other], clients: [], history: history, blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        #expect(try all(ctx).contains { $0.groupName == "Innocent Ensemble" })
    }

    // Suppression stays CONFIDENT-match-only, which is the existing DNC rule and worth keeping: a
    // merely similar name is never authoritative enough to silently drop a real show Dan would want.
    // Dropping a good show in silence is its own kind of harm.
    @Test func aMerelySimilarNameIsNotSilentlyDropped() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "New York Chorale")
        OrgDoNotContact.mark(orgOf: p, in: try all(ctx))
        let history = LocalHistory.records(from: try all(ctx))

        let different = ExtractedEvent(title: "New York Theatre Ballet Company of Manhattan",
                                       presenter: nil, venue: "Weill Recital Hall",
                                       performanceDate: "2027-09-11", sourceUrl: "https://example.com/x")
        _ = ScoutService.apply(events: [different], clients: [], history: history, blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        #expect(try all(ctx).contains { $0.performanceDate == "2027-09-11" })
    }

    // MARK: - Marking has to clean up the PRESENT, not just the future

    // Otherwise Dan marks the org off-limits and still has three of their other shows sitting in his
    // queue, drafted and ready to send. The future is protected and the present is armed.
    @Test func markingAlsoClearsTheOrgsOtherUnsentShowsOutOfTheQueue() throws {
        let ctx = ModelContext(try container())
        let refused = make(ctx, group: "Refused Chorale", date: "2026-09-12")
        let sibling = make(ctx, group: "Refused Chorale", date: "2026-11-04")
        let other = make(ctx, group: "Innocent Ensemble", date: "2026-11-04")

        OrgDoNotContact.mark(orgOf: refused, in: try all(ctx))

        #expect(sibling.status == .dismissed)
        #expect(sibling.orgDoNotContact)
        #expect(other.status == .queued)      // a different org is untouched
        #expect(!other.orgDoNotContact)
    }

    // A show already emailed is real outreach history and stays, but nothing further may go out on it:
    // its untried contacts are suppressed, and it reads as closed so no follow-up or reminder fires.
    // A follow-up to an org that asked you to stop is exactly the email this issue exists to prevent.
    @Test func anAlreadySentShowKeepsItsHistoryButCanNeverSendAgain() throws {
        let ctx = ModelContext(try container())
        let sent = make(ctx, group: "Refused Chorale", status: .contacted, sentAt: Date())
        let pending = Recipient(id: "r1", email: "someone@refused.org", name: "Someone",
                                provenance: .act)
        sent.addRecipient(pending)
        try ctx.save()

        OrgDoNotContact.mark(orgOf: sent, in: try all(ctx))

        #expect(sent.status == .contacted)                       // history preserved, not rewritten
        #expect(sent.recipients.first?.sendState == .suppressed) // but nothing more goes out
        #expect(sent.isClosed)                                   // so no follow-up or reminder fires
    }

    // MARK: - The entry point the UI actually calls

    // ProspectMutations.setOrgDoNotContact is what the "Never contact this org again" button in the
    // reply-triage dialog invokes, and what the row's "Allow contact again" undo invokes. Tested here
    // rather than through the dialog's presentation, because what matters is that the answer Dan gives
    // reaches the store: a dialog that renders beautifully and marks nothing is the bug.
    @Test func theUiEntryPointMarksAndReleasesTheOrg() throws {
        let ctx = ModelContext(try container())
        let refused = make(ctx, group: "Refused Chorale", date: "2026-09-12")
        let sibling = make(ctx, group: "Refused Chorale", date: "2026-11-04")
        let feedback = ActionFeedback()
        let item = QueueItem(refused)

        ProspectMutations.setOrgDoNotContact(item, true, prospects: try all(ctx),
                                             context: ctx, feedback: feedback)

        #expect(refused.orgDoNotContact)
        #expect(sibling.orgDoNotContact)          // the org's OTHER shows too, not just this one
        #expect(sibling.status == .dismissed)     // and out of the queue, not merely flagged

        ProspectMutations.setOrgDoNotContact(item, false, prospects: try all(ctx),
                                             context: ctx, feedback: feedback)

        #expect(!refused.orgDoNotContact)
        #expect(!sibling.orgDoNotContact)
    }

    // MARK: - Reversible

    // A mis-click must not be permanent. Unmarking releases the org so a future scout surfaces it
    // again; the individual shows it dismissed stay dismissed and are restored from Archive as usual,
    // because silently resurrecting Dan's dismissals would be its own surprise.
    @Test func unmarkingReleasesTheOrgForFutureScouts() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Refused Chorale")
        OrgDoNotContact.mark(orgOf: p, in: try all(ctx))

        OrgDoNotContact.unmark(orgOf: p, in: try all(ctx))

        #expect(!p.orgDoNotContact)
        #expect(!p.isClosed)
        let history = LocalHistory.records(from: try all(ctx))
        #expect(!history.contains { $0.status == "dnc" })

        let returning = ExtractedEvent(title: "Refused Chorale", presenter: "Refused Chorale",
                                       venue: "Weill Recital Hall", performanceDate: "2027-09-11",
                                       sourceUrl: "https://example.com/back")
        _ = ScoutService.apply(events: [returning], clients: [], history: history, blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        #expect(try all(ctx).contains { $0.performanceDate == "2027-09-11" })
    }
}
