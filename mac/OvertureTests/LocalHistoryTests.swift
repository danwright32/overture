import Testing
import Foundation
import SwiftData
@testable import Overture

// #19: a one-time CSV import goes stale as Dan works. Instead, recognition history is
// derived live from Overture's own activity — orgs it has emailed are "contacted",
// booked outcomes are "booked" — so repeat-client matching never goes stale.
@MainActor
@Suite("Local history from Overture activity")
struct LocalHistoryTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func make(_ ctx: ModelContext, group: String, status: ReviewStatus,
                      sentAt: Date? = nil, outcome: Outcome = .noResponse,
                      dismissReason: DismissReason? = nil) -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status, dismissReason: dismissReason)
        p.sentAt = sentAt
        p.outcome = outcome
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
        make(ctx, group: "Busy Day Opera", status: .dismissed, dismissReason: .alreadyBooked)
        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(records.first?.status == "declined")
    }

    @Test func notAFitDismissalIsNotDeclined() throws {
        // A "not a fit" dismissal is Dan's judgment, not a scheduling miss: it stays neutral.
        let ctx = ModelContext(try container())
        make(ctx, group: "Wrong Fit Quartet", status: .dismissed, sentAt: Date(), dismissReason: .notInterested)
        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(records.first?.status == "contacted")
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
