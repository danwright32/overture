import Testing
import Foundation
import SwiftData

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
                         venue: "Hall", performanceDate: date, sourceListingURL: nil,
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

    @Test func dayStringUsesEasternNotUTC() {
        // 2026-07-01 23:30 America/New_York (EDT, UTC-4) is 2026-07-02 03:30 UTC. The send-day
        // must be the Eastern day (Dan's timezone, the zone Downbeat authors its dates in), so a
        // pitch sent late evening ET does not slip onto the next UTC day and shift the causation
        // cutoff (#116).
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let lateEveningET = utc.date(from: DateComponents(year: 2026, month: 7, day: 2, hour: 3, minute: 30))!
        #expect(BookingMatch.dayString(from: lateEveningET) == "2026-07-01")
    }

    @Test func venueBreaksTieAmongSameOrgAndDate() {
        // Two bookings match the same org and date range. The prospect's venue confidently
        // matches the SECOND one, so venue (a soft tiebreaker) must select it over the first.
        let p = prospect()
        p.venue = "Carnegie Hall"
        let first = booking(id: "B-tie-first", start: "2026-03-10", end: "2026-03-12",
                            venueName: "Town Hall")
        let second = booking(id: "B-tie-second", start: "2026-03-10", end: "2026-03-12",
                             venueName: "Carnegie Hall")
        let r = BookingMatch.classify(prospect: p, bookings: [first, second])
        if case .exact(let matched) = r {
            #expect(matched.id == "B-tie-second")
        } else {
            Issue.record("expected venue to break the tie to B-tie-second, got \(r)")
        }
    }

    @Test func venueNeverRejectsALoneMatch() {
        // A single causally-valid org+date booking whose venue does NOT match the prospect's
        // venue must still be an exact match. Venue is a soft tiebreaker only: it never rejects
        // or downgrades an otherwise-exact match.
        let p = prospect()
        p.venue = "Carnegie Hall"
        let b = booking(id: "B-lone", start: "2026-03-10", end: "2026-03-12",
                        venueName: "Somewhere Else Entirely")
        let r = BookingMatch.classify(prospect: p, bookings: [b])
        if case .exact(let matched) = r {
            #expect(matched.id == "B-lone")
        } else {
            Issue.record("expected .exact despite venue mismatch, got \(r)")
        }
    }

    @Test func firstMatchKeptWhenNoVenueMatches() {
        // Two bookings tie on org and date; neither venue matches the prospect's venue.
        // Behavior is unchanged: the first causally-valid candidate wins.
        let p = prospect()
        p.venue = "Carnegie Hall"
        let first = booking(id: "B-nofit-first", start: "2026-03-10", end: "2026-03-12",
                            venueName: "Town Hall")
        let second = booking(id: "B-nofit-second", start: "2026-03-10", end: "2026-03-12",
                             venueName: "Symphony Space")
        let r = BookingMatch.classify(prospect: p, bookings: [first, second])
        if case .exact(let matched) = r {
            #expect(matched.id == "B-nofit-first")
        } else {
            Issue.record("expected first-match fallback B-nofit-first, got \(r)")
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
