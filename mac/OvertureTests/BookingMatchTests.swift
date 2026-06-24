import Testing
import Foundation
import SwiftData
@testable import Overture

@MainActor
@Suite("Booking match rule")
struct BookingMatchTests {
    private func booking(client: String = "C1", start: String, end: String,
                         venueId: String? = nil, venueName: String = "Hall") -> OvertureBooking {
        OvertureBooking(id: "B", clientId: client, clientDisplayName: "Every Voice Choirs",
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
        let r = BookingMatch.classify(prospect: prospect(),
            bookings: [booking(start: "2026-03-10", end: "2026-03-12")],
            clientDisplayNames: ["C1": "Every Voice Choirs"])
        #expect(r == .exact)
    }

    @Test func multiDayBoundaryInclusive() {
        let r = BookingMatch.classify(prospect: prospect(date: "2026-03-12"),
            bookings: [booking(start: "2026-03-10", end: "2026-03-12")],
            clientDisplayNames: [:])
        #expect(r == .exact)
    }

    @Test func noneWhenDateOutsideRange() {
        let r = BookingMatch.classify(prospect: prospect(date: "2026-03-20"),
            bookings: [booking(start: "2026-03-10", end: "2026-03-12")],
            clientDisplayNames: [:])
        #expect(r == .none)
    }

    @Test func possibleWhenBookingPredatesSend() {
        let p = prospect(sentDaysAgo: -5)
        let r = BookingMatch.classify(prospect: p,
            bookings: [booking(start: "2026-03-10", end: "2026-03-12")],
            clientDisplayNames: [:])
        #expect(r == .possible)
    }

    @Test func noneWhenNeverSent() {
        let r = BookingMatch.classify(prospect: prospect(sentDaysAgo: nil),
            bookings: [booking(start: "2026-03-10", end: "2026-03-12")],
            clientDisplayNames: [:])
        #expect(r == .none)
    }

    @Test func nilDateNeverMatches() {
        let r = BookingMatch.classify(prospect: prospect(date: nil),
            bookings: [booking(start: "2026-03-10", end: "2026-03-12")],
            clientDisplayNames: [:])
        #expect(r == .none)
    }

    @Test func nameFallbackWhenClientIdNil() {
        let r = BookingMatch.classify(prospect: prospect(clientId: nil),
            bookings: [booking(start: "2026-03-10", end: "2026-03-12")],
            clientDisplayNames: ["C1": "Every Voice Choirs"])
        #expect(r == .exact)
    }
}
