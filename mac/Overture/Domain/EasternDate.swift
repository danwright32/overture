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
    //
    // #3749: a FAST PATH for the canonical shape, and the formatter for everything else.
    //
    // WHY NOT SIMPLY REPLACE THE FORMATTER. Because its contract is not what it looks like, which was
    // measured rather than assumed before this was written. It ROLLS OVER out of range days
    // (`2026-04-31` gives 1 May, `2023-02-29` gives 1 March, `1900-02-29` gives 1 March) while rejecting
    // an out of range MONTH (`2026-13-01` is nil). It accepts loose digit counts (`2026-1-5`), a
    // three digit year (`226-01-05` is year 226) and a five digit one, surrounding whitespace, and
    // Arabic-Indic digits (`٢٠٢٦-٠١-٠٥` is 5 January 2026). Reproducing all of that by hand is
    // reimplementing ICU's lenient parsing, and getting it subtly wrong would change what
    // `QueueModel.nightTimes` treats as a readable entry, which is a VALIDATION and not a conversion.
    //
    // So the fast path handles ONLY the shape every stored date in this app actually has, exactly four
    // digits, a dash, two digits, a dash, two digits, with the month in 1...12 and the day inside that
    // month's real length, and hands everything else to the formatter unchanged. The fallback IS the old
    // implementation, so the contract cannot drift: what the fast path does not answer, the same code as
    // before answers (L263).
    //
    // WHAT IT IS WORTH. A formatter parse is about 11 microseconds. The queue's render pass makes roughly
    // 1,090 of them, two per show for the lead-time window, and #3748 measured a single parse over the
    // store's rows at 13.5 ms of a 31.3 ms term.
    static func date(from dayString: String) -> Date? {
        if let fast = canonicalDay(dayString) { return fast }
        return dayFormatter.date(from: dayString)
    }

    // The canonical `yyyy-MM-dd`, or nil for anything the formatter should judge instead.
    //
    // Nil here NEVER means invalid: it means "not the shape this can answer", and the caller falls back.
    // That is the whole reason this is safe, and it is why the strictness below costs nothing: a shape it
    // turns down is not rejected, only handed on.
    private static func canonicalDay(_ text: String) -> Date? {
        let c = Array(text.utf8)
        guard c.count == 10, c[4] == UInt8(ascii: "-"), c[7] == UInt8(ascii: "-") else { return nil }

        func digits(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let byte = c[index]
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        // The RANGES that matter, and only those. The month must be 1...12 and the day 1...31, because
        // those are the two the formatter REJECTS outright (`2026-13-01` and `2026-01-32` are both nil)
        // and where `Calendar.date(from:)` would instead roll over into a different month and disagree.
        //
        // A PER MONTH day limit is deliberately NOT checked, and that is a finding rather than a
        // simplification. The first version of this carried one, with the full Gregorian leap rule
        // beside it, and a mutation replacing that rule with the naive `year % 4 == 0` SURVIVED the whole
        // equivalence corpus. The reason is that `Calendar.date(from:)` rolls an out of range day over
        // exactly as the formatter does: `2026-04-31` becomes 1 May and `1900-02-29` becomes 1 March
        // either way. So the precision distinguished nothing, no test could make it fail, and code no
        // test can tell from its absence is code arguing for itself (L29, L1).
        guard let year = digits(0..<4), let month = digits(5..<7), let day = digits(8..<10),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        return calendar.date(from: DateComponents(year: year, month: month, day: day))
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

    // #2615: ONE month vocabulary. The short form is derived from the long one rather than kept beside
    // it, because two hand-maintained lists that must agree month for month is exactly the drift L41
    // describes, and every English month's three-letter form is its own first three letters.
    private static let longMonths = ["January", "February", "March", "April", "May", "June",
                                     "July", "August", "September", "October", "November", "December"]

    private static let shortMonths = longMonths.map { String($0.prefix(3)) }

    static func shortMonth(_ component: Int) -> String { shortMonths[(component - 1 + 12) % 12] }

    static func longMonth(_ component: Int) -> String { longMonths[(component - 1 + 12) % 12] }

    // A day string as Dan reads it: "Nov 14". Nil for an unparseable day, so a caller has to say what it
    // wants to show instead rather than being handed a plausible-looking wrong date.
    static func dayLabel(_ day: String) -> String? {
        guard let d = date(from: day) else { return nil }
        return "\(shortMonth(calendar.component(.month, from: d))) \(calendar.component(.day, from: d))"
    }

    // The same day spelled out, for PROSE rather than for a dense list: "August 11". #2615's closing
    // note is the first caller, and an outbound sentence under Dan's name is not the place for "Aug".
    // Nil for an unparseable day, the same contract as dayLabel.
    static func longDayLabel(_ day: String) -> String? {
        guard let d = date(from: day) else { return nil }
        return "\(longMonth(calendar.component(.month, from: d))) \(calendar.component(.day, from: d))"
    }

    // The same day WITH its year: "Nov 2, 2025". For a fact about the past rather than about the queue.
    // #2007 is the first caller: it dates an email Dan sent, which on an annual show is routinely a year
    // or more back, and "Nov 2" alone would read as this coming November.
    static func dayLabelWithYear(_ date: Date) -> String {
        let day = dayString(from: date)
        let label = dayLabel(day) ?? day
        return "\(label), \(calendar.component(.year, from: date))"
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
