import Foundation

// #1127: Green Room 42 (and any *.venuetix.com venue) is a VenueTix single-page app; a plain fetch reads
// as a shell showing "0 Events". Its events load from a public cloud-function feed the SPA calls,
// `/clientApi/client/nine-events`, which despite the name returns the COMPLETE upcoming list in one
// request, scoped to the venue by the request's Origin/Referer (the venue's own subdomain). Reading the
// feed is deterministic and hashable, so unlike a browser render it is safe for the content hash and the
// reconcile. The venue NAME is not in the feed or the static page (the page title is set by JavaScript),
// so it is threaded in from the WatchedSource's orgName.
enum VenueTixCalendar {
    struct VTEvent: Equatable {
        var title: String
        var superTitle: String?
        var subTitle: String?
        var date: Date
    }

    private struct Item: Decodable {
        var title: String
        var superTitle: String?
        var subTitle: String?
        var dateTime: Double?   // epoch MILLISECONDS
    }

    static func parseEvents(_ data: Data) throws -> [VTEvent] {
        try JSONDecoder().decode([Item].self, from: data).compactMap { item in
            // A row we cannot date is not a listing we can pitch or reconcile, so drop it rather than
            // invent a date. Every real row has carried dateTime, so this is a guard, not an expected path.
            guard let ms = item.dateTime else { return nil }
            return VTEvent(title: item.title,
                           superTitle: item.superTitle,
                           subTitle: item.subTitle,
                           date: Date(timeIntervalSince1970: ms / 1000))
        }
    }

    // Keep shows whose start instant is now-or-later; a show already begun cannot be pitched. Filtering a
    // COMPLETE feed to a stable rule keeps the reconcile honest: a show leaves the set only once it is
    // genuinely past (then it retires by date, #864), never because a partial read shrank the list.
    static func upcoming(_ events: [VTEvent], now: Date) -> [VTEvent] {
        events.filter { $0.date >= now }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // Renders the events as one plain HTML document the extractor reads like any fetched page. Every show
    // is attributed to the venue by NAME (threaded from the source) and carries an EXPLICIT ISO date.
    // copy-inventory:ignore-start  synthesized source HTML the extractor reads, not the app's voice (#915)
    static func listingHTML(_ events: [VTEvent], venueName: String) -> String {
        let rows = events.map { e -> String in
            let bits = [e.superTitle, e.subTitle].compactMap { $0 }.filter { !$0.isEmpty }
                .map { "<p>\($0)</p>" }.joined()
            return "<article><h2>\(e.title)</h2>\(bits)<p>\(dayFormatter.string(from: e.date)) at \(venueName)</p></article>"
        }.joined(separator: "\n")
        return "<section title=\"\(venueName)\">\n\(rows)\n</section>"
    }
    // copy-inventory:ignore-end

    // The VenueTix events feed. Fixed cloud-function URL; the venue is chosen by the request's Origin.
    private static let feedURL = "https://us-east1-venuetixprod.cloudfunctions.net/clientApi/client/nine-events"

    // True for any *.venuetix.com host (each venue is a subdomain). Suffix match so a look-alike like
    // `venuetix.com.evil.com` or `evilvenuetix.com` never routes here.
    static func handles(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "venuetix.com" || host.hasSuffix(".venuetix.com")
    }

    // copy-inventory:ignore-start  an outbound API request scoped by Origin, not the app's voice (#915)
    static func feedRequest(forVenueHost host: String) -> URLRequest {
        var req = URLRequest(url: URL(string: feedURL)!)
        // The feed returns "Unauthorized access" without the venue's own subdomain as Origin/Referer.
        req.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        req.setValue("https://\(host)", forHTTPHeaderField: "Origin")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36",
                     forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        return req
    }
    // copy-inventory:ignore-end

    // Reads the venue's complete upcoming list in ONE request, filters to now-or-later, and synthesizes one
    // document. `get` is injected so the network is testable. A failed fetch THROWS (never an empty
    // document): an empty list would read to the reconcile as "every show was cancelled".
    static func fetch(url: URL, venueName: String, now: Date,
                      get: (URLRequest) async throws -> Data) async throws -> FetchedPage {
        let host = url.host ?? ""
        let data = try await get(feedRequest(forVenueHost: host))
        let events = upcoming(try parseEvents(data), now: now)
        let html = PageNormalizer.normalize(listingHTML(events, venueName: venueName))
        return FetchedPage(normalizedHTML: html,
                           finalURL: url.absoluteString,
                           contentHash: PageNormalizer.contentHash(html))
    }

    // The real network fetch, used by the router.
    static func liveFetch(url: URL, venueName: String, now: Date = Date(),
                          session: URLSession = .shared) async throws -> FetchedPage {
        try await fetch(url: url, venueName: venueName, now: now) { req in
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw SourceFetchError.unreachable
            }
            return data
        }
    }
}
