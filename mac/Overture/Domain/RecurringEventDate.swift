import Foundation

// #1126: normalize the date a RECURRING listing carries, so a fabricated far-future placeholder never
// reaches a prospect.
//
// Dan's first real scout read Jalopy Theatre's "Jalopy Open Mic Every Wednesday!" and the run handed
// back performanceDate 2028-03-15. That is not a real date: a weekly listing has no single performance
// day, and the run invented one to fill the field. The harm is silent and total: performanceDate drives
// the Prep four-month cutoff (#953) and the calendar horizon, so a show dated 2028 is quietly held out
// of Prep, shown to Dan with a wrong date, and read as the truth by every date-based sort and the
// "performance passed" logic.
//
// The rule is safety-first, mirroring the venue guard's "never put a wrong fact in front of Dan":
//
//   - A non-recurring listing is returned exactly as it came back. This is not a general far-future
//     sanity cap: a real one-off show IS routinely booked a year or more out, and dropping those would
//     be its own silent data loss. The recurring TITLE is the signal that the date is a placeholder, so
//     that is the only thing that triggers a rewrite.
//   - A recurring listing that names a weekday resolves to the NEXT occurrence of that weekday from
//     today (in Eastern time, the app's single clock). That is the honest, stable answer and it is what
//     Prep and the calendar actually want.
//   - A recurring listing with no determinable weekday ("Weekly Jam Session") OMITS the date. A nil
//     performanceDate is a normal "date to be confirmed" state the rest of the app already handles
//     (EasternDate: an unknown date has not passed and collides with nothing); emitting the run's
//     placeholder instead would be exactly the fiction this exists to prevent.
enum RecurringEventDate {
    // Weekday name -> Calendar weekday value (Sunday = 1 ... Saturday = 7), matching Foundation's
    // Gregorian calendar so it lines up with EasternDate.calendar's .weekday component.
    private static let weekdays: [(name: String, value: Int)] = [
        ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4),
        ("thursday", 5), ("friday", 6), ("saturday", 7)
    ]

    // A title reads as recurring when it carries a repetition keyword (every / each / weekly /
    // recurring) or names a weekday in the PLURAL ("Open Mic Wednesdays"). A bare singular weekday
    // ("Wednesday Night Jazz") is deliberately NOT enough: it is an ordinary one-off show name, and
    // treating it as recurring would rewrite a perfectly good date.
    static func isRecurring(title: String) -> Bool {
        let t = title.lowercased()
        if t.range(of: #"\b(every|each|weekly|recurring)\b"#, options: .regularExpression) != nil {
            return true
        }
        return weekdays.contains { t.range(of: "\\b\($0.name)s\\b", options: .regularExpression) != nil }
    }

    // The weekday the title names, singular or plural, if any. Consulted only once a title is already
    // known to be recurring, so a lone weekday here is safe.
    static func weekday(in title: String) -> Int? {
        let t = title.lowercased()
        return weekdays.first { t.range(of: "\\b\($0.name)s?\\b", options: .regularExpression) != nil }?.value
    }

    // The first occurrence of `weekday` on or after `today`, as an Eastern day string. Returns today
    // itself when today already is that weekday. Nil only if `today` is unparseable (a programming
    // error); the caller then omits rather than falling back to the placeholder.
    static func nextOccurrence(of weekday: Int, onOrAfter today: String) -> String? {
        guard let base = EasternDate.date(from: today) else { return nil }
        let calendar = EasternDate.calendar
        let current = calendar.component(.weekday, from: base)
        let delta = ((weekday - current) % 7 + 7) % 7
        guard let next = calendar.date(byAdding: .day, value: delta, to: base) else { return nil }
        return EasternDate.dayString(from: next)
    }

    // The date a possibly-recurring listing should carry. See the type comment for the three cases.
    static func resolvedDate(title: String, performanceDate: String?, today: String) -> String? {
        guard isRecurring(title: title) else { return performanceDate }
        guard let weekday = weekday(in: title) else { return nil }
        return nextOccurrence(of: weekday, onOrAfter: today)
    }

    // Apply the rule to one extracted event, leaving every other field alone.
    static func normalized(_ event: ExtractedEvent, today: String) -> ExtractedEvent {
        var event = event
        event.performanceDate = resolvedDate(title: event.title,
                                             performanceDate: event.performanceDate, today: today)
        return event
    }
}
