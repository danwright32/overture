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
            guard perfDate >= booking.startDate && perfDate <= booking.endDate else {
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

    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    static func dayString(from date: Date) -> String {
        let comps = utcCalendar.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 0
        let m = comps.month ?? 0
        let d = comps.day ?? 0
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}
