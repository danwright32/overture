import Testing
import Foundation
import SwiftData
@testable import Overture

@MainActor
@Suite("Booking match rule")
struct BookingMatchTests {
    private func booking(id: String = "B", client: String = "C1", start: String, end: String,
                         venueId: String? = nil, venueName: String = "Hall") -> OvertureBooking {
        OvertureBooking(id: id, clientId: client, clientDisplayName: "Every Voice Choirs",
            shootName: "", startDate: start, endDate: end, venueId: venueId, venueName: venueName)
    }

    private func prospect(clientId: String? = "C1", date: String? = "2026-03-11",
                          sentDaysAgo: Int? = 30, group: String = "Every Voice Choirs") -> Prospect {
        let p = Prospect(naturalKey: UUID().uuidString, groupName: group, discipline: "choral",
                         venue: "Hall", performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.downbeatClientId = clientId
        if let d = sentDaysAgo {
            p.sentAt = Date(timeIntervalSince1970: 1_773_100_800 - Double(d) * 86_400)
        }
        return p
    }

    @Test func exactWhenIdAndDateInRangeAndSentBefore() {
        let b = booking(id: "B-exact-1", start: "2026-03-10", end: "2026-03-12")
        let r = BookingMatch.classify(prospect: prospect(), bookings: [b])
        if case .exact(let matched) = r {
            #expect(matched.id == "B-exact-1")
        } else {
            Issue.record("expected .exact, got \(r)")
        }
    }

    @Test func multiDayBoundaryInclusive() {
        let b = booking(id: "B-boundary", start: "2026-03-10", end: "2026-03-12")
        let r = BookingMatch.classify(prospect: prospect(date: "2026-03-12"), bookings: [b])
        if case .exact(let matched) = r {
            #expect(matched.id == "B-boundary")
        } else {
            Issue.record("expected .exact, got \(r)")
        }
    }

    @Test func noneWhenDateOutsideRange() {
        let r = BookingMatch.classify(prospect: prospect(date: "2026-03-20"),
            bookings: [booking(start: "2026-03-10", end: "2026-03-12")])
        #expect(r == .none)
    }

    @Test func possibleWhenBookingPredatesSend() {
        let p = prospect(sentDaysAgo: -5)
        let r = BookingMatch.classify(prospect: p,
            bookings: [booking(start: "2026-03-10", end: "2026-03-12")])
        #expect(r == .possible)
    }

    @Test func noneWhenNeverSent() {
        let r = BookingMatch.classify(prospect: prospect(sentDaysAgo: nil),
            bookings: [booking(start: "2026-03-10", end: "2026-03-12")])
        #expect(r == .none)
    }

    @Test func nilDateNeverMatches() {
        let r = BookingMatch.classify(prospect: prospect(date: nil),
            bookings: [booking(start: "2026-03-10", end: "2026-03-12")])
        #expect(r == .none)
    }

    @Test func nameFallbackWhenClientIdNil() {
        let r = BookingMatch.classify(prospect: prospect(clientId: nil),
            bookings: [booking(start: "2026-03-10", end: "2026-03-12")])
        if case .exact = r {} else {
            Issue.record("expected .exact, got \(r)")
        }
    }

    @Test func bookingMatchesAnyNightOfARun() {
        // Run spans 2026-03-10 to 2026-03-12; booking covers only the last night
        let p = prospect(date: "2026-03-10")
        p.runEndDate = "2026-03-12"
        let b = booking(id: "B-run-overlap", start: "2026-03-12", end: "2026-03-12")
        let r = BookingMatch.classify(prospect: p, bookings: [b])
        if case .exact(let matched) = r {
            #expect(matched.id == "B-run-overlap")
        } else {
            Issue.record("expected .exact for a booking on a later night of the run, got \(r)")
        }
    }

    @Test func bookingOutsideRunRangeDoesNotMatch() {
        // Run spans 2026-03-10 to 2026-03-12; booking is entirely after the run
        let p = prospect(date: "2026-03-10")
        p.runEndDate = "2026-03-12"
        let b = booking(start: "2026-03-20", end: "2026-03-20")
        let r = BookingMatch.classify(prospect: p, bookings: [b])
        #expect(r == .none)
    }
}
