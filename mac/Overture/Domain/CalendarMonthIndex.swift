import Foundation

// #858: a calendar hands you the month you landed on, and nothing else.
//
// Kaufman's landing page carries July's 6 shows. August (2), September (8) and October (14) live on
// their own pages and were never read. The dropped months are the VALUABLE ones: pitching a performance
// needs lead time, so October's fourteen shows are far more pitchable than the ones happening next week.
//
// The route to them is the site's OWN month index, a <select> of month URLs:
//
//     <option value="https://www.kaufmanmusiccenter.org/mch/calendar/2026/10/">October 2026</option>
//
// which is why #892 had to land first: `value` was being stripped, so the index was deleted from the
// bytes we kept before anything could read it.
//
// This type ONLY reads what the page already published about itself. It never invents a URL and never
// guesses a pattern. The issue as filed assumed Kaufman paginated by /P20, /P40; it does not, and
// /P20 answers 200 with page one's content, so an implementation that guessed URLs would have fetched
// the same page four times and reported a complete sweep. Guessing is the failure mode here, so the
// rule is: follow the site's own links, or fetch nothing at all.
enum CalendarMonthIndex {
    // Four, and it is a HARD cap rather than a target (Dan's call, 2026-07-13). Kaufman lists 21 months
    // out to January 2028. Reading all of them would multiply the cost of every scout forever to reach
    // shows too far out to pitch, and an AI re-read fires whenever ANY fetched page changes.
    //
    // #1571: this is the SUPPLY side of a pair. The queue only shows the next
    // [[QueueModel.leadTimeWindowDays]] days, and the relationship between the two (why they differ,
    // and what the buffer is for) is written down in one place, at that constant. Read it before
    // changing this number. Four months reaches 89 days at its shortest, on 31 January of a non leap
    // year, which since #3423 took the window to 63 clears it on every date; at 90 it fell one day
    // short on that one date, and that is why the pair is measured rather than assumed.
    static let defaultHorizon = 4

    // What a page's own month navigation tells us: the months we can go and read, and the months it
    // NAMES but whose links are a shape we cannot follow.
    struct Index: Equatable, Sendable {
        // The month pages worth fetching: the month we are in, plus the next few, in order.
        //
        // Fewer than two means "do not paginate", and that is the common case. Dan pastes single show
        // pages, homepages and Substack posts, and none of them should quietly start fetching extra pages.
        var pages: [URL] = []

        // #900. Months inside the horizon that the calendar advertises and we cannot reach ("2026-10").
        //
        // Kaufman's month lives in the PATH (/2026/10/) and that is the one shape we can follow. A month
        // in a query (?month=2026-10), in a fragment, or behind an opaque "next" link resolves to no URL
        // at all, and the source is read exactly one month deep.
        //
        // Reading nothing there is correct: guessing a URL pattern is what made the original #858 premise
        // dangerous (its assumed /P20 answers 200 with page ONE's content, so a guesser would have fetched
        // the same page four times and reported a complete sweep). Reading nothing SILENTLY is not
        // correct. One month of a busy hall looks exactly like four months of a quiet one, which is the
        // app's normal off-season state, so the cap has to be able to say its own name.
        var unreachableMonths: [String] = []
    }

    static func index(in normalizedHTML: String, at pageURL: URL, now: Date,
                      horizon: Int = defaultHorizon) -> Index {
        guard horizon > 0, let host = pageURL.host else { return Index() }
        let current = Month(now)

        // The months we can actually GO to: a link the page offers, whose URL carries a month we can read.
        var reachable: [Month: URL] = [:]
        for candidate in linkedURLs(in: normalizedHTML, relativeTo: pageURL) {
            // Never leave the site. Another site's calendar is another organization's shows, and filing
            // them under this lead is exactly the confusion #888 exists to prevent.
            guard let h = candidate.host, sameSite(h, host) else { continue }
            guard let month = Month(pathOf: candidate) else { continue }
            // A month that has already gone by cannot be pitched, so it is not worth a fetch. This is
            // also what keeps a blog archive (/2024/03/, /2024/04/, ... by the dozen) from being
            // mistaken for a calendar: every one of its months is in the past.
            guard month >= current, reachable[month] == nil else { continue }
            reachable[month] = candidate
        }

        // The window is what the calendar OFFERS us for the season ahead, whether or not we can fetch it,
        // capped at the horizon. Built from both halves on purpose: a month we cannot reach still occupies
        // its place in the four we would have read, so it displaces a fifth month rather than being
        // quietly backfilled by one.
        let offered = Set(reachable.keys).union(advertisedMonths(in: normalizedHTML, at: pageURL, host: host)
                                                    .filter { $0 >= current })
        let window = offered.sorted().prefix(horizon)

        return Index(
            pages: window.compactMap { reachable[$0] },
            // The month we LANDED on is never missing: it is the page in our hands. Saying we could not
            // read July, on the page whose July shows we just read, would simply be false.
            unreachableMonths: window.filter { reachable[$0] == nil && $0 != current }.map(\.label))
    }

    // Every URL the page offers, from the two attributes a month index actually uses: `href` for a list
    // of links, and `value` for the <select> Kaufman uses (its dropdown navigates by
    // `window.location = $(this).val()`).
    private static func linkedURLs(in html: String, relativeTo base: URL) -> [URL] {
        guard let re = try? NSRegularExpression(pattern: "(?:href|value)=\"([^\"]{1,300})\"") else { return [] }
        let ns = html as NSString
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .compactMap { URL(string: ns.substring(with: $0.range(at: 1)), relativeTo: base)?.absoluteURL }
    }

    // The months a calendar NAMES: the visible text of a link or a <select> option ("October 2026").
    //
    // Read from the text rather than from the URL, because the URL is precisely what we could not
    // understand. This is also what keeps the signal honest. A month index is a NAVIGATION CONTROL, so
    // only a link's or an option's own text counts; a date in a sentence ("a concert on October 3rd")
    // does not, which is what stops every single show page from claiming to be a calendar.
    //
    // A label whose link LEAVES the site is dropped. We refused that month on purpose (#888), and refused
    // is not unreachable: reporting it would send Dan looking for a month that was never his.
    private static func advertisedMonths(in html: String, at base: URL, host: String) -> [Month] {
        guard let re = try? NSRegularExpression(
            pattern: "<(option|a)(\\s[^>]*)?>(.*?)</\\1\\s*>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString

        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let month = Month(label: PageNormalizer.visibleText(ns.substring(with: m.range(at: 3))))
            else { return nil }
            let attributes = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
            if let url = linkedURLs(in: attributes, relativeTo: base).first,
               let h = url.host, !sameSite(h, host) { return nil }
            return month
        }
    }

    private static func sameSite(_ a: String, _ b: String) -> Bool {
        func canon(_ h: String) -> String {
            var s = h.lowercased()
            if s.hasPrefix("www.") { s.removeFirst(4) }
            return s
        }
        return canon(a) == canon(b)
    }

    // A year and a month, comparable, with no time zone and no day in it. The calendar's own labels are
    // the only thing being compared, so anything finer would be inventing precision the page never had.
    struct Month: Comparable, Hashable, Sendable {
        let year: Int
        let month: Int

        init(year: Int, month: Int) {
            self.year = year
            self.month = month
        }

        // "Now" is Eastern, like every other date judgement in this app: Dan is in New York and so are
        // the calendars. On the first of a month, a UTC reading would still be in the previous month for
        // several hours and would fetch a stale window.
        init(_ date: Date) {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
            let c = cal.dateComponents([.year, .month], from: date)
            self.year = c.year ?? 0
            self.month = c.month ?? 0
        }

        // Reads /2026/10/ out of a path. Deliberately strict: a four-digit year in a plausible range and
        // a real month number, so an id like /12345/99/ is not read as a date.
        init?(pathOf url: URL) {
            guard let re = try? NSRegularExpression(pattern: "/(20\\d{2})/(0[1-9]|1[0-2])(?:/|$)") else { return nil }
            let path = url.path
            let ns = path as NSString
            guard let m = re.firstMatch(in: path, range: NSRange(location: 0, length: ns.length)),
                  let y = Int(ns.substring(with: m.range(at: 1))),
                  let mo = Int(ns.substring(with: m.range(at: 2)))
            else { return nil }
            self.year = y
            self.month = mo
        }

        // Reads "October 2026" (or "Oct 2026") out of a month index's own label. Deliberately strict: the
        // whole label, and nothing but the label. A YEAR IS REQUIRED, so "October" alone is not read, and
        // neither is a sentence that happens to contain a month.
        //
        // The year matters more than it looks. Without one there is no way to tell next October from last
        // October, and the month a calendar advertises is only worth reporting BECAUSE it is still ahead.
        // If a real source turns up whose select says only "October", widen this then, against that page:
        // guessing at shapes in advance is the mistake #858 already made once.
        init?(label: String) {
            let names = ["january", "february", "march", "april", "may", "june",
                         "july", "august", "september", "october", "november", "december"]
            let words = label.lowercased().split(separator: " ")
            guard words.count == 2, let year = Int(words[1]), (2000...2099).contains(year) else { return nil }
            let word = String(words[0])
            guard let i = names.firstIndex(where: { $0 == word || (word.count >= 3 && $0.hasPrefix(word)) })
            else { return nil }
            self.year = year
            self.month = i + 1
        }

        var label: String { String(format: "%04d-%02d", year, month) }

        static func < (a: Month, b: Month) -> Bool {
            (a.year, a.month) < (b.year, b.month)
        }
    }
}
