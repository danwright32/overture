import Foundation

enum BookingMatchResult: Equatable {
    case exact(OvertureBooking)
    case possible
    case none
}

enum BookingMatch {
    static func classify(
        prospect: Prospect,
        bookings: [OvertureBooking]
    ) -> BookingMatchResult {
        guard let perfDate = prospect.performanceDate else { return .none }
        guard let sentAt = prospect.sentAt else { return .none }

        let sendDay = dayString(from: sentAt)

        var best: BookingMatchResult = .none
        // Collect every causally-valid org+date match in encounter order so venue can break a
        // tie among them. A booking that predates the send still demotes us to .possible.
        var exactCandidates: [OvertureBooking] = []
        for booking in bookings {
            guard orgMatches(booking: booking, prospect: prospect) else {
                continue
            }
            let runStart = perfDate
            let runEnd = prospect.runEndDate ?? perfDate
            guard runStart <= booking.endDate && runEnd >= booking.startDate else {
                continue
            }
            let causallyValid = booking.startDate >= sendDay
            if causallyValid {
                exactCandidates.append(booking)
            } else {
                best = .possible
            }
        }

        guard let firstExact = exactCandidates.first else { return best }
        // Venue is a SOFT tiebreaker: prefer the candidate whose venue confidently matches the
        // prospect's venue, but fall back to the first encountered when none do. It never rejects
        // or downgrades an otherwise-exact match.
        let venueMatch = exactCandidates.first { candidate in
            GroupNameMatch.isConfident(candidate.venueName, prospect.venue ?? "")
        }
        return .exact(venueMatch ?? firstExact)
    }

    private static func orgMatches(
        booking: OvertureBooking,
        prospect: Prospect
    ) -> Bool {
        if let clientId = prospect.downbeatClientId {
            return booking.clientId == clientId
        }
        return GroupNameMatch.isConfident(booking.clientDisplayName, prospect.groupName)
    }

    // The send-day is derived in Dan's timezone (the zone Downbeat authors its booking day-strings
    // in) so a pitch sent late evening Eastern doesn't slip onto the next UTC day and shift the
    // causation cutoff (#116). Delegates to the shared EasternDate helper, the one source of truth.
    static func dayString(from date: Date) -> String {
        EasternDate.dayString(from: date)
    }
}
