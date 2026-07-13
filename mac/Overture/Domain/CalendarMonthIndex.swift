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
    static let defaultHorizon = 4

    // The month pages worth fetching: the month we are in, plus the next few, in order.
    //
    // Empty means "this is not a month calendar, do not paginate", and that is the common case. Dan
    // pastes single show pages, homepages and Substack posts, and none of them should quietly start
    // fetching extra pages.
    static func monthPages(in normalizedHTML: String, at pageURL: URL, now: Date,
                           horizon: Int = defaultHorizon) -> [URL] {
        guard horizon > 0, let host = pageURL.host else { return [] }
        let current = Month(now)

        var seen = Set<String>()
        var found: [(Month, URL)] = []
        for candidate in linkedURLs(in: normalizedHTML, relativeTo: pageURL) {
            // Never leave the site. Another site's calendar is another organization's shows, and filing
            // them under this lead is exactly the confusion #888 exists to prevent.
            guard let h = candidate.host, sameSite(h, host) else { continue }
            guard let month = Month(pathOf: candidate) else { continue }
            // A month that has already gone by cannot be pitched, so it is not worth a fetch. This is
            // also what keeps a blog archive (/2024/03/, /2024/04/, ... by the dozen) from being
            // mistaken for a calendar: every one of its months is in the past.
            guard month >= current else { continue }
            guard seen.insert(candidate.absoluteString).inserted else { continue }
            found.append((month, candidate))
        }

        return found.sorted { $0.0 < $1.0 }.prefix(horizon).map(\.1)
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

        var label: String { String(format: "%04d-%02d", year, month) }

        static func < (a: Month, b: Month) -> Bool {
            (a.year, a.month) < (b.year, b.month)
        }
    }
}
