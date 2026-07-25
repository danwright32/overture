import Foundation

// Business-day counting, reckoned in Eastern time like everything else (#116). The hire-inquiry
// follow-up nudge fires at 3 business days of silence (#1435), so a Friday send is not nagged on
// Monday. No such helper existed before; this is the one source of truth for it.
enum BusinessDay {
    // Weekdays (Mon through Fri) strictly AFTER `start`'s day, up to and including `end`'s day. Zero
    // when `end` is the same day as or before `start`, never negative.
    static func count(after start: Date, through end: Date) -> Int {
        let cal = EasternDate.calendar
        let startDay = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)
        guard endDay > startDay else { return 0 }
        var count = 0
        var day = cal.date(byAdding: .day, value: 1, to: startDay)!
        while day <= endDay {
            let weekday = cal.component(.weekday, from: day)   // Sunday = 1 ... Saturday = 7
            if weekday != 1 && weekday != 7 { count += 1 }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return count
    }

    // #1513: the inverse of `count`. The day that is `businessDays` weekdays strictly AFTER `start`,
    // which is when a nudge counted by `count` becomes due. Defined against the same walk, so
    // `count(after: start, through: advance(start, by: n)) == n` holds by construction rather than by
    // two pieces of arithmetic agreeing.
    static func advance(_ start: Date, byBusinessDays businessDays: Int) -> Date {
        let cal = EasternDate.calendar
        var day = cal.startOfDay(for: start)
        guard businessDays > 0 else { return day }
        var remaining = businessDays
        while remaining > 0 {
            day = cal.date(byAdding: .day, value: 1, to: day)!
            let weekday = cal.component(.weekday, from: day)   // Sunday = 1 ... Saturday = 7
            if weekday != 1 && weekday != 7 { remaining -= 1 }
        }
        return day
    }
}
