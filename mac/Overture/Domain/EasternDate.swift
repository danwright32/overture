import Foundation

// Overture is ALWAYS reckoned in New York time, never UTC or the Mac's local zone, so "is this in
// the past / how many days until the show" never drifts a day off near midnight (#116). This is the
// single source of truth for that day-string math, consolidating the logic that was duplicated in
// QueueModel and BookingMatch, and the basis for the conversation-reminder event-aware timing (#111).
enum EasternDate {
    static let timeZone = TimeZone(identifier: "America/New_York")!

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // An instant rendered as its Eastern calendar day ("yyyy-MM-dd").
    static func dayString(from date: Date) -> String {
        dayFormatter.string(from: date)
    }

    // Today (or any instant), as the Eastern day string. Alias of dayString for call-site clarity.
    static func today(_ now: Date = Date()) -> String {
        dayString(from: now)
    }

    // Parse an Eastern day string back to the Date at that day's Eastern midnight.
    static func date(from dayString: String) -> Date? {
        dayFormatter.date(from: dayString)
    }

    // Whole Eastern calendar days from one day string to another. Negative if `to` is before
    // `from`; nil if either string is unparseable.
    static func daysUntil(from: String, to: String) -> Int? {
        guard let f = date(from: from), let t = date(from: to) else { return nil }
        return calendar.dateComponents([.day], from: f, to: t).day
    }
}
