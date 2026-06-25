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

    // Dan's timezone, the zone Downbeat authors its booking start/end day-strings in. The
    // send-day is derived here in the same zone so a pitch sent late evening Eastern doesn't
    // slip onto the next UTC day and shift the causation cutoff (#116).
    private static var easternCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    static func dayString(from date: Date) -> String {
        let comps = easternCalendar.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 0
        let m = comps.month ?? 0
        let d = comps.day ?? 0
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}
