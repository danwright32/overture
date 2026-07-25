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
}
