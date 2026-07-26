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

    // Every Eastern day from one day string to another, inclusive of both ends (#901): a booking, a
    // vacation and a multi-night run are all ranges, and all three have to be asked about day by day.
    //
    // Capped, because two of those three ranges come from data we do not control: a scraped runEndDate is
    // whatever an org's season page happened to say, and "2999-01-01" would otherwise walk a third of a
    // million days before answering. A year is far past any real run or vacation.
    //
    // A backwards range (end before start) is bad data, not a block on the days in between, so it yields
    // its start day alone rather than an empty list: a show still happens on its opening night even if
    // the page's closing date is nonsense.
    static let maxRangeDays = 366

    static func days(from start: String, through end: String, maxDays: Int = maxRangeDays) -> [String] {
        guard let startDate = date(from: start) else { return [] }
        guard let endDate = date(from: end), endDate >= startDate else { return [start] }

        var out: [String] = []
        var cursor = startDate
        while cursor <= endDate && out.count < maxDays {
            out.append(dayString(from: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return out
    }

    private static let shortMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func shortMonth(_ component: Int) -> String { shortMonths[(component - 1 + 12) % 12] }

    // A day string as Dan reads it: "Nov 14". Nil for an unparseable day, so a caller has to say what it
    // wants to show instead rather than being handed a plausible-looking wrong date.
    static func dayLabel(_ day: String) -> String? {
        guard let d = date(from: day) else { return nil }
        return "\(shortMonth(calendar.component(.month, from: d))) \(calendar.component(.day, from: d))"
    }

    // MARK: - The run window (#798)
    //
    // Two places ask "is this run over?": the scout's import guard (should this show enter the queue
    // at all?) and FeedReconcile (did this show vanish from the feed because it was cancelled, or
    // because it simply happened?). Both used to derive it themselves. One definition now.

    // A run is judged by its CLOSING night, never its opening one, so a show that opened last week and
    // runs through next week is still a live show.
    static func runLastNight(runEndDate: String?, performanceDate: String?) -> String? {
        runEndDate ?? performanceDate
    }

    // Strictly behind us. An UNKNOWN date has not passed: "date to be confirmed" is a normal listing
    // state on an org's season page, and dropping it would silently lose a real show (#798).
    static func runHasPassed(lastNight: String?, today: String) -> Bool {
        guard let lastNight else { return false }
        return lastNight < today
    }

    // #1540: has the run STARTED? Judged on its OPENING night, the mirror image of runHasPassed above,
    // and the near edge of the triage queue since Dan ruled that a client's need for photos is over once
    // they have opened. Strictly behind us, so a run opening TONIGHT has not started (his distinction,
    // made after being shown both readings). An UNKNOWN date has not opened, for the same reason it has
    // not passed: "date to be confirmed" is a normal listing state, and dropping it would lose a real
    // show (#798). One definition, because the triage filter and Prospect both ask it.
    static func runHasOpened(openingNight: String?, today: String) -> Bool {
        guard let openingNight else { return false }
        return openingNight < today
    }

    // Known to be today or later. Deliberately NOT `!runHasPassed`: an unknown date is neither passed
    // nor confirmed-live. Reconcile needs THIS one, so an undated prospect never accrues
    // "disappeared from the feed" misses on the strength of a date nobody has. The asymmetry is the
    // whole reason both live here, spelled out, instead of one being expressed as the other.
    static func runIsLive(lastNight: String?, today: String) -> Bool {
        guard let lastNight else { return false }
        return lastNight >= today
    }
}
