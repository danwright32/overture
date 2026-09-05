import Foundation

// Carnegie's public calendar (/events) is a thin front-end over an Algolia search index
// (prod_Events). The visible page only renders ~3 days at a time, but the index holds the
// whole season, so the scout queries Algolia directly for the next 90 days in one call
// instead of scraping the paginated DOM. These are the same public, search-only credentials
// the website ships in its own client JS (not secrets), captured from a live request. If
// Carnegie rotates the key or restructures the index, this is the spot to update.
enum AlgoliaCalendar {
    static let appID = "Q0TMLOPF1J"
    static let apiKey = "d2d2b382f2659c44ef8927aad7a24172"
    static let index = "prod_Events"
    static let endpoint = URL(string: "https://Q0TMLOPF1J-dsn.algolia.net/1/indexes/*/queries")!

    // How far ahead the scout looks. Past performances and anything beyond this are not worth pitching.
    //
    // #2521: 120, and the days over the queue's display window ([[QueueModel.leadTimeWindowDays]]) are
    // the POINT rather than slack. This is the SUPPLY side of the pair #1571 wrote down: supply must
    // exceed demand so a show is already in the store by the time it rolls into Dan's triage window.
    //
    // #3423 took the display window from 90 to 63, so the margin here is now 57 days rather than 30.
    // The fetch was deliberately NOT narrowed to follow it. It is supply, Dan's call was about how far
    // ahead he is SHOWN a show rather than about how far ahead one is collected, and #2521's whole
    // argument was for a wider margin than this source had. Narrowing it back toward the window is the
    // thing that would need deciding, and `QueueWindowAndScoutHorizonTests` still holds the floor at a
    // month so that decision cannot be made silently.
    //
    // It used to be 90, exactly the display window, so it "mirrored" it. That is the one arrangement the
    // pair must not have: a Carnegie show became fetchable and became pitchable on the same day, so
    // whether it was in the store when Dan could first act on it depended on a scout run landing in the
    // right order rather than on any margin. Nothing absorbed a night the scout did not run, a read Dan
    // deferred, or a feed that was briefly unreadable.
    //
    // Every other source has that margin without anyone choosing it, because a whole calendar month is a
    // coarser unit than a day: [[CalendarMonthIndex.defaultHorizon]]'s four months reach 89 to 122 days,
    // which now clears the window on every date of the year. Counted in days, the margin has to be
    // picked, and thirty put this source in the same family as the other two.
    //
    // Carnegie is why it is worth the fetch: 122 of 322 shoots in Dan's history, 38% of everything he has
    // photographed, and it is the store's only `algolia` source.
    //
    // `QueueWindowAndScoutHorizonTests` measures this against the display window from the constants
    // themselves and fails if either moves, so changing one is a deliberate act rather than silent drift.
    static let windowDays = 120
    static let hitsPerPage = 1000
    // A safety stop so a surprise in the index can never spin the pager forever.
    static let maxPages = 5

    // Eastern day boundaries via the shared helper (#177), so this window math can't drift from the
    // rest of the app's date handling (#116).
    private static let easternCalendar = EasternDate.calendar

    // The index stores `startdate` as a millisecond epoch. The window opens at midnight (New
    // York) of today and runs to midnight of the day after the last included day, so every
    // performance on day+windowDays is covered. Lower bound inclusive, upper exclusive.
    static func windowBoundsMs(today: Date, windowDays: Int = windowDays) -> (start: Int, end: Int) {
        let startOfToday = easternCalendar.startOfDay(for: today)
        let startDay = easternCalendar.date(byAdding: .day, value: 0, to: startOfToday) ?? startOfToday
        let endExclusive = easternCalendar.date(byAdding: .day, value: windowDays + 1, to: startOfToday) ?? startOfToday
        return (Int(startDay.timeIntervalSince1970 * 1000), Int(endExclusive.timeIntervalSince1970 * 1000))
    }

    // The Algolia `params` query string: empty text query, the startdate window as numeric
    // filters, sorted by date ascending via the index's default ranking.
    static func params(startMs: Int, endMs: Int, hitsPerPage: Int = hitsPerPage, page: Int) -> String {
        let numeric = "[\"startdate>=\(startMs)\",\"startdate<\(endMs)\"]"
        let encoded = numeric.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? numeric
        return "query=&hitsPerPage=\(hitsPerPage)&page=\(page)&numericFilters=\(encoded)"
    }

    static func requestBody(startMs: Int, endMs: Int, page: Int) -> Data {
        let payload = "{\"requests\":[{\"indexName\":\"\(index)\",\"params\":\"\(params(startMs: startMs, endMs: endMs, page: page))\"}]}"
        return Data(payload.utf8)
    }

    private struct Response: Decodable { let results: [ResultPage] }
    private struct ResultPage: Decodable { let hits: [Hit]; let nbPages: Int? }
    private struct Hit: Decodable {
        let title: String
        let licenseename: String?
        let facility: String?
        let url: String?
    }

    // Maps one page of Algolia hits to the same ExtractedEvent shape the rest of the scout
    // pipeline already classifies. `licenseename` is the presenter/renter (drives self vs
    // agency), `facility` is the venue, and the date comes from the /calendar/yyyy/mm/dd url.
    static func parse(_ data: Data) -> (events: [ExtractedEvent], nbPages: Int) {
        guard let resp = ResponseBody.decode(Response.self, from: data,
                                             endpoint: "algolia.search").value,
              let page = resp.results.first else { return ([], 0) }
        let events = page.hits
            .filter { !isCancelled($0.title) }
            .map { hit in
                ExtractedEvent(
                    title: cleanText(hit.title),
                    presenter: hit.licenseename.flatMap(nonBlank),
                    venue: hit.facility.flatMap(nonBlank),
                    performanceDate: hit.url.flatMap(dateFromCalendarURL),
                    sourceUrl: hit.url.map { "https://www.carnegiehall.org\($0)" }
                )
            }
        return (events, page.nbPages ?? 1)
    }

    // The feed sometimes embeds HTML (e.g. <br/>) and zero-width characters in text fields.
    // Drop tags, strip zero-width/carriage-return noise, and collapse the resulting whitespace.
    static func cleanText(_ s: String) -> String {
        let noTags = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let noNoise = noTags.replacingOccurrences(of: "\u{200B}", with: "").replacingOccurrences(of: "\r", with: "")
        let collapsed = noNoise.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonBlank(_ s: String) -> String? {
        let t = cleanText(s)
        return t.isEmpty ? nil : t
    }

    // Cancelled performances ride along in the feed with a "Cancelled:" title prefix; they are
    // noise Dan can't pitch, so they are dropped at parse time.
    private static func isCancelled(_ title: String) -> Bool {
        title.range(of: "^\\s*cancell?ed\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func dateFromCalendarURL(_ url: String) -> String? {
        guard let m = url.range(of: #"/calendar/(\d{4})/(\d{2})/(\d{2})/"#, options: .regularExpression) else { return nil }
        let parts = url[m].split(separator: "/")
        // ["calendar", "yyyy", "mm", "dd"]
        guard parts.count >= 4 else { return nil }
        return "\(parts[1])-\(parts[2])-\(parts[3])"
    }
}
