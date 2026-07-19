import Foundation

// #1127: OPERA America's calendar page is a JavaScript app; a plain fetch reads as "readable" but carries
// no events, so the scout's rescue never fires. Its events actually load from a public Umbraco feed the
// page's own front-end calls: `POST /umbraco/surface/calendar/filtered` with a date-range JSON body,
// returning a paginated JSON list. This adapter reads that feed directly, which is deterministic and
// hashable (unlike a browser render), so it is safe for the content hash and the reconcile.
enum OperaAmericaCalendar {
    struct OAEvent: Equatable {
        var title: String
        var company: String
        var date: Date
        var time: String?
        var venue: String?
        var city: String?
        var state: String?
        var eventLink: String?
    }

    struct OAPage: Equatable {
        var totalPages: Int
        var totalItems: Int
        var events: [OAEvent]
    }

    private struct Envelope: Decodable {
        var totalPages: Int
        var totalItems: Int
        var items: [Item]
    }

    private struct Item: Decodable {
        var title: String
        var company: String?
        var date: String
        var time: String?
        var venue: String?
        var city: String?
        var state: String?
        var eventLink: String?
    }

    // The feed dates arrive zoneless ("2026-07-18T00:00:00") and mean a local calendar day, so they are
    // parsed in the current time zone. Only the day matters downstream (horizon + geography), not the clock.
    private static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    static func parsePage(_ data: Data) throws -> OAPage {
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        let events: [OAEvent] = env.items.compactMap { item in
            // A row we cannot date is not a listing we can safely pitch or reconcile, so drop it rather than
            // invent a date. The feed has always carried a date, so this is a guard, not an expected path.
            guard let date = dateParser.date(from: item.date) else { return nil }
            return OAEvent(title: item.title,
                           company: item.company ?? "",
                           date: date,
                           time: item.time,
                           venue: item.venue,
                           city: item.city,
                           state: item.state,
                           eventLink: item.eventLink)
        }
        return OAPage(totalPages: env.totalPages, totalItems: env.totalItems, events: events)
    }

    // yyyy-MM-dd in the current zone, matching how the feed dates were parsed. Stable output so the
    // synthesized document (and thus the content hash) does not churn between runs on identical feed data.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // Renders the events as one plain HTML document the extractor reads exactly like any fetched page. Each
    // event carries an EXPLICIT ISO date (never implied), its company, its venue/city/state, and the ticket
    // link, so a real listing can be pulled out. copy-inventory:ignore-start  synthesized source HTML the
    // extractor reads, not the app's own voice to Dan (#915)
    static func listingHTML(_ events: [OAEvent]) -> String {
        let rows = events.map { e -> String in
            let place = [e.venue, [e.city, e.state].compactMap { $0 }.joined(separator: ", ")]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            let when = [dayFormatter.string(from: e.date), e.time].compactMap { $0 }.joined(separator: " ")
            let link = e.eventLink.map { "<a href=\"\($0)\">Tickets</a>" } ?? ""
            return """
            <article><h2>\(e.title)</h2><p>\(e.company)</p><p>\(when)</p><p>\(place)</p>\(link)</article>
            """
        }.joined(separator: "\n")
        return "<section title=\"OPERA America National Opera Calendar\">\n\(rows)\n</section>"
    }
    // copy-inventory:ignore-end

    // Reads every page of the feed and joins them into ONE document with ONE hash. `post` fetches a page's
    // raw JSON (injected so pagination is testable without the network). CRITICAL: if any page fails, the
    // whole fetch throws. It must never return the pages it did get as a "complete" list, because a short
    // list reads to the reconcile as "the rest were cancelled" and would strike real shows (#1127).
    static func fetch(url: URL, post: (Int) async throws -> Data) async throws -> FetchedPage {
        let first = try await parsePage(try await post(1))
        var events = first.events
        if first.totalPages > 1 {
            for pageNumber in 2...first.totalPages {
                let next = try await parsePage(try await post(pageNumber))
                events.append(contentsOf: next.events)
            }
        }
        let html = PageNormalizer.normalize(listingHTML(events))
        return FetchedPage(normalizedHTML: html,
                           finalURL: url.absoluteString,
                           contentHash: PageNormalizer.contentHash(html))
    }

    // True for OPERA America's own host only. Exact-host match so a look-alike like
    // `operaamerica.org.evil.com` never routes here.
    static func handles(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "operaamerica.org" || host == "www.operaamerica.org"
    }

    // Builds one page's POST to the Umbraco feed. Pure and testable so the real endpoint/body is pinned
    // without the network. copy-inventory:ignore-start  an outbound API request body, not the app's voice (#915)
    static func filteredRequest(host: String, from: Date, to: Date, page: Int, pageSize: Int) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://\(host)/umbraco/surface/calendar/filtered")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        // #1170: pre-narrow the national calendar (350+ upcoming) to exactly the geography gate's in-range
        // states, cutting the synthesized document (and per-scout AI read cost) roughly threefold. The feed
        // accepts state CODES (verified live 2026-07-18: "NY" filters, "New York" returns nothing), and is
        // case-insensitive. Deriving from EventPlace.inRangeStateCodes guarantees it can never narrow harder
        // than the gate and drop a NYC-metro show sitting in NJ or CT.
        let states = EventPlace.inRangeStateCodes.map { $0.uppercased() }
        let body: [String: Any] = [
            "q": "", "coq": "", "types": [], "zip": "", "states": states,
            "from": dayFormatter.string(from: from), "to": dayFormatter.string(from: to),
            "companyId": 0, "page": page, "pageSize": pageSize, "companies": []
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }
    // copy-inventory:ignore-end

    // The real network fetch: reads every page from the live feed over a horizon window. `from`..`to`
    // default to now through four months out, matching the scout's calendar horizon.
    static func liveFetch(url: URL, now: Date = Date(), pageSize: Int = 100,
                          session: URLSession = .shared) async throws -> FetchedPage {
        let host = url.host ?? "www.operaamerica.org"
        let to = Calendar.current.date(byAdding: .month, value: 4, to: now) ?? now
        return try await fetch(url: url) { page in
            let req = filteredRequest(host: host, from: now, to: to, page: page, pageSize: pageSize)
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw SourceFetchError.unreachable
            }
            return data
        }
    }
}
