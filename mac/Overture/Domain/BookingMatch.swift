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
                return .exact(booking)
            } else {
                best = .possible
            }
        }
        return best
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
