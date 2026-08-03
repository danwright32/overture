import Foundation

// #1983: every feed reader states a day, and three of them also state a clock. Both are read HERE, in ONE
// zone, and that zone is Eastern (`EasternDate`), never the Mac's own.
//
// Each adapter used to hold its own `DateFormatter` pinned to `.current`, with a comment beside it
// promising its day and its time were read in the same zone. Five copies of one promise is how two of them
// drift apart, so the promise is structural now: a caller asks for a day or a time, not for a formatter.
//
// The zone is a PARAMETER rather than something captured, for a reason that outlives the bug. On Dan's Mac
// `.current` IS Eastern, so a test asserting an absolute day string passes whether a reader reads Eastern
// or the host clock, and `TZ=UTC` does not reach the test host (the bundle runs inside a launched app,
// where `TimeZone.current` reads the system preference, not the environment). A zone that can be handed in
// is the only seam that lets a guard here be SEEN to fail on the machine it ships from.
enum FeedDates {
    // Every feed reader's default, and the same zone the rest of Overture reckons in.
    static let defaultZone = EasternDate.timeZone

    // The Eastern path delegates to EasternDate rather than keeping a second Eastern day formatter that
    // could drift from it. Any other zone is a test's, so it builds a formatter on demand instead of
    // paying for a cache the shipping path never reads.
    static func day(from date: Date, zone: TimeZone = defaultZone) -> String {
        guard zone != defaultZone else { return EasternDate.dayString(from: date) }
        return formatter("yyyy-MM-dd", zone).string(from: date)
    }

    // A "yyyy-MM-dd" day string back to that day's midnight IN THIS ZONE. Nil for anything unparseable, so
    // a caller decides what to do rather than being handed a plausible-looking wrong instant.
    static func date(day: String, zone: TimeZone = defaultZone) -> Date? {
        guard zone != defaultZone else { return EasternDate.date(from: day) }
        return formatter("yyyy-MM-dd", zone).date(from: day)
    }

    // #1699: the clock a feed published, as "HH:mm". Deliberately the same entry point as `day` above, so a
    // show's day and its curtain time cannot be read in two zones and disagree about which night it is.
    static func time(from date: Date, zone: TimeZone = defaultZone) -> String {
        guard zone != defaultZone else { return easternTime.string(from: date) }
        return formatter("HH:mm", zone).string(from: date)
    }

    // A zoneless timestamp a feed publishes in its own local terms ("2026-07-18T00:00:00"), read in this
    // zone. Nil when the string does not match the format, never a guessed instant.
    static func date(_ raw: String, format: String, zone: TimeZone = defaultZone) -> Date? {
        formatter(format, zone).date(from: raw)
    }

    // The zone's own midnight, for the "is this show still upcoming" boundary. A day-granular feed has to
    // ask that question against the day Dan is living in, not the day the host clock happens to be on.
    static func startOfDay(_ date: Date, zone: TimeZone = defaultZone) -> Date {
        calendar(zone).startOfDay(for: date)
    }

    static func calendar(_ zone: TimeZone = defaultZone) -> Calendar {
        guard zone != defaultZone else { return EasternDate.calendar }
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    private static let easternTime = formatter("HH:mm", defaultZone)

    private static func formatter(_ format: String, _ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = format
        return f
    }
}
