import Testing
import Foundation
import SwiftData

// #19: a one-time CSV import goes stale as Dan works. Instead, recognition history is
// derived live from Overture's own activity — orgs it has emailed are "contacted",
// booked outcomes are "booked" — so repeat-client matching never goes stale.
@MainActor
@Suite("Local history from Overture activity")
struct LocalHistoryTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func make(_ ctx: ModelContext, group: String, status: ReviewStatus,
                      venue: String = "V",
                      sentAt: Date? = nil, outcome: Outcome = .noResponse,
                      showOutcome: ShowOutcome? = nil,
                      dismissReason: ShowOutcome? = nil) -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "choral", venue: venue,
                         performanceDate: "2026-07-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status, dismissReason: dismissReason)
        p.sentAt = sentAt
        p.outcome = outcome
        if let showOutcome { p.showOutcome = showOutcome }
        ctx.insert(p)
        return p
    }

    @Test func emailedProspectsBecomeContactedHistory() throws {
        let ctx = ModelContext(try container())
        make(ctx, group: "Emailed Choir", status: .approved, sentAt: Date())
        make(ctx, group: "Untouched Choir", status: .new)            // never sent -> no record
        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(records.count == 1)
        #expect(records.first?.groupName == "Emailed Choir")
        #expect(records.first?.status == "contacted")
    }

    // #351/#384: "Don't want to shoot this" is a personal-taste pass on one event. Unlike a
    // scheduling miss (which keeps the org a hot "declined" lead), it must not make the ORG cold.
    //
    // #351 achieved that by recording nothing at all, which also meant the pass was forgotten
    // entirely and the identical recurring show came back next season scoring just as high. The
    // record now exists and CARRIES THE VENUE, so the penalty can be aimed at exactly the show Dan
    // passed on (org AND venue) and at nothing else. The venue is what makes the record safe to keep:
    // without it, this would be an org-wide black mark, which is precisely what #351 was avoiding.
    @Test func personalPassIsRecordedAgainstTheShowItWasAboutNotTheOrg() throws {
        let ctx = ModelContext(try container())
        make(ctx, group: "Passed Org", status: .dismissed,
             venue: "Weill Recital Hall", dismissReason: .dontWantToShoot)

        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))

        #expect(records.count == 1)
        #expect(records.first?.status == "passed")
        #expect(records.first?.venue == "Weill Recital Hall")
        #expect(ShowOutcome.dontWantToShoot.label == "Don't want to shoot this")
    }

    // "Not a fit" stays genuinely neutral: it is a judgement about the show, not a standing pass Dan
    // wants remembered, so it must still record nothing.
    @Test func aNotAFitDismissalStillRecordsNothing() throws {
        let ctx = ModelContext(try container())
        make(ctx, group: "Wrong Fit Org", status: .dismissed, dismissReason: .notAFit)
        #expect(LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>())).isEmpty)
    }

    @Test func bookedOutcomeBecomesBookedHistory() throws {
        let ctx = ModelContext(try container())
        make(ctx, group: "Booked Band", status: .approved, sentAt: Date(), outcome: .booked)
        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(records.first?.status == "booked")
    }

    @Test func repliedOutcomeBecomesWarmHistory() throws {
        // They wrote back with interest: a real warm relationship, not a cold send.
        let ctx = ModelContext(try container())
        make(ctx, group: "Interested Ensemble", status: .approved, sentAt: Date(), outcome: .replied)
        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(records.first?.status == "warm")
    }

    @Test func aRepliedContactIsWarmEvenWithoutALeadReplyRollup() throws {
        // Phase F: the A3 lead rollup is gone, so warmth derives from a contact replying. Lead
        // outcome stays noResponse; a replied recipient still marks the relationship warm.
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Replied Contact", status: .approved, sentAt: Date(), outcome: .noResponse)
        let r = Recipient(id: "c@e.com", email: "c@e.com", provenance: .act)
        r.sendState = .sent
        r.replied = true
        p.setRecipients([r])
        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(records.first?.status == "warm")
    }

    @Test func dateConflictDismissalBecomesDeclined() throws {
        // 1.2: Dan skipped it only because he was already booked that day — a hot future lead,
        // not a dead end.
        let ctx = ModelContext(try container())
        make(ctx, group: "Clash Chorale", status: .dismissed, dismissReason: .dateConflict)
        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(records.first?.status == "declined")
    }

    @Test func alreadyBookedDismissalBecomesDeclined() throws {
        let ctx = ModelContext(try container())
        make(ctx, group: "Busy Day Opera", status: .dismissed, dismissReason: .hadPaidWork)
        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(records.first?.status == "declined")
    }

    @Test func notAFitDismissalIsNotDeclined() throws {
        // A "not a fit" dismissal is Dan's judgment, not a scheduling miss: it stays neutral.
        let ctx = ModelContext(try container())
        make(ctx, group: "Wrong Fit Quartet", status: .dismissed, sentAt: Date(), dismissReason: .notAFit)
        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(records.first?.status == "contacted")
    }

    @Test func asoftNoBecomesLostSoftHistory() throws {
        // They said not now: a small negative, still above a cold stranger. #2399: read off the one field.
        // This used to be written as `Outcome.lostSoft`, which nothing in the app has ever written, so the
        // assertion passed on a path no real row could reach (#2401).
        let ctx = ModelContext(try container())
        make(ctx, group: "Maybe Later Choir", status: .approved, sentAt: Date(),
             showOutcome: .theySaidNotNow)
        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(records.first?.status == "lost_soft")
    }

    @Test func arefusalBecomesLostHardHistory() throws {
        // They said no: a heavy penalty that still stays visible.
        let ctx = ModelContext(try container())
        make(ctx, group: "Never Again Opera", status: .approved, sentAt: Date(),
             showOutcome: .theySaidNo)
        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(records.first?.status == "lost_hard")
    }

    @Test func legacyPassedOutcomeMigratesToLostSoft() throws {
        // Old booking rows stored a single ambiguous "passed"; it now reads as soft lost.
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Old Passed Org", status: .approved, sentAt: Date())
        p.outcomeRaw = "passed"
        #expect(p.outcome == .lostSoft)
    }

    @Test func recognitionStaysCurrentAcrossScouts() throws {
        // An org Overture emailed last cycle is recognized as contacted when it reappears.
        let ctx = ModelContext(try container())
        make(ctx, group: "Acme Festival Chorus", status: .approved, sentAt: Date())
        let derived = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))

        let verdict = HistoryMatch.matchRelationship(name: "Acme Festival Chorus", clients: [], history: derived)
        #expect(verdict.relationship == .contacted)
    }
}
