import Testing
import Foundation
import SwiftData
@testable import Overture

// #41: Downbeat is the canonical booking record. When a prospect we actually contacted
// turns out to be a Downbeat client, mark its outcome booked (source auto) as ground
// truth — but only for contacted prospects (so repeat clients we never pitched aren't
// falsely booked), and never over a manual decision.
@MainActor
@Suite("Downbeat auto-booked")
struct DownbeatBookingTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func make(_ ctx: ModelContext, group: String, status: ReviewStatus,
                      outcome: Outcome = .noResponse, source: OutcomeSource? = nil) -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        p.outcome = outcome
        p.outcomeSourceRaw = source?.rawValue
        ctx.insert(p)
        return p
    }

    private func client(_ name: String) -> DownbeatClient {
        DownbeatClient(id: UUID().uuidString, displayName: name, shortName: nil, email: "a@x.org",
                       contractEmail: "a@x.org", phoneNumber: nil, isTaxExempt: nil, hasLeftReview: false,
                       specialBehaviors: [], notes: nil, hostingSite: "x.org")
    }

    @Test func contactedMatchBecomesBookedAuto() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved)
        let now = Date(timeIntervalSince1970: 5_000)

        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [client("Acme Festival Chorus")], now: now)
        #expect(count == 1)
        #expect(p.outcome == .booked)
        #expect(p.outcomeSourceRaw == OutcomeSource.auto.rawValue)
        #expect(p.outcomeAt == now)
    }

    @Test func alreadyAClientWhenPitchedIsNotReBooked() throws {
        // #66: the org was already a booked client when Dan pitched this event, so a client-list
        // match is just the pre-existing relationship, not a new conversion. Don't auto-book it.
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved)
        p.priorRelationshipAtSend = "booked"

        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [client("Acme Festival Chorus")], now: Date())
        #expect(count == 0)
        #expect(p.outcome == .noResponse)
    }

    @Test func coldWhenPitchedThatBecomesAClientIsBooked() throws {
        // The attributable case: cold at contact, now a Downbeat client — a genuine new booking.
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved)
        p.priorRelationshipAtSend = "none"

        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [client("Acme Festival Chorus")], now: Date())
        #expect(count == 1)
        #expect(p.outcome == .booked)
    }

    @Test func uncontactedMatchIsLeftAlone() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Acme Festival Chorus", status: .queued)   // kept but never sent/approved
        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [client("Acme Festival Chorus")], now: Date())
        #expect(count == 0)
        #expect(p.outcome == .noResponse)
    }

    @Test func manualOutcomeIsNeverOverwritten() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved, outcome: .lostSoft, source: .manual)
        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [client("Acme Festival Chorus")], now: Date())
        #expect(count == 0)
        #expect(p.outcome == .lostSoft)   // Dan's call stands
    }

    @Test func noClientMatchLeavesItAlone() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Unrelated Ensemble", status: .approved)
        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [client("Acme Festival Chorus")], now: Date())
        #expect(count == 0)
        #expect(p.outcome == .noResponse)
    }
}
