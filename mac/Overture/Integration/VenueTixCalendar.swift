import Foundation

// #1127: Green Room 42 (and any *.venuetix.com venue) is a VenueTix single-page app; a plain fetch reads
// as a shell showing "0 Events". Its events load from a public cloud-function feed the SPA calls,
// `/clientApi/client/nine-events`, which despite the name returns the COMPLETE upcoming list in one
// request, scoped to the venue by the request's Origin/Referer (the venue's own subdomain). Reading the
// feed is deterministic and hashable, so unlike a browser render it is safe for the content hash and the
// reconcile. The venue NAME is not in the feed or the static page (the page title is set by JavaScript),
// so it is threaded in from the WatchedSource's orgName.
enum VenueTixCalendar {
    struct VTEvent: Equatable, Sendable {
        var title: String
        var superTitle: String?
        var subTitle: String?
        var date: Date
        // #1680: the feed's own per-event id. With seriesId it addresses the venue's own page for this
        // exact night (/showdetails/{seriesId}/{eventId}, the route the venue's own listing cards use).
        var eventId: String? = nil
        // #1174: the feed's own production id, shared by every night of one show. Nil when the feed names
        // none. It is the authoritative "these dates are one production" signal (it does not depend on
        // titles matching or nights being close together, so a weekly residency still reads as one show).
        // For any production that spans MORE THAN ONE night in a document, listingHTML stamps each of its
        // nights with a shared `Series:` tag the extractor copies into the event's seriesId, and
        // RunGrouping collapses those nights into one run that renders an opening-to-closing span.
        var seriesId: String? = nil
    }

    // #1174: the production id ties every night of one show together. Captured live it is a JSON string
    // ("seriesId":"s1"), but tolerate a number or null too so a single field's type can never fail the
    // whole parse; anything empty or absent yields no id, and those rows simply never collapse.
    private struct SeriesID: Decodable {
        let value: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { value = nil }
            else if let s = try? c.decode(String.self) { value = s.isEmpty ? nil : s }
            else if let i = try? c.decode(Int.self) { value = String(i) }
            else if let d = try? c.decode(Double.self) { value = String(Int(d)) }
            else { value = nil }
        }
    }

    private struct Item: Decodable {
        var title: String
        var superTitle: String?
        var subTitle: String?
        var dateTime: Double?   // epoch MILLISECONDS
        var eventId: SeriesID?  // #1680: same tolerant decode as seriesId, for the same reason
        var seriesId: SeriesID?
    }

    static func parseEvents(_ data: Data) throws -> [VTEvent] {
        let items: [Item]
        do {
            items = try JSONDecoder().decode([Item].self, from: data)
        } catch let error as DecodingError {
            // #1184: a NON-EMPTY body we could not decode is a FORMAT change (a required field like `title`
            // drifted), and must read the same clear "format has probably changed" way as the all-dropped
            // guard below, not the misleading "couldn't reach that page" a raw DecodingError maps to
            // (ScoutService.fetchError). An empty body is genuine no-content, so it keeps its original error.
            guard !data.isEmpty else { throw error }
            throw SourceFetchError.feedShapeChanged
        }
        let events: [VTEvent] = items.compactMap { item in
            // A row we cannot date is not a listing we can pitch or reconcile, so drop it rather than
            // invent a date. Every real row has carried dateTime, so this is a guard, not an expected path.
            guard let ms = item.dateTime else { return nil }
            return VTEvent(title: item.title,
                           superTitle: item.superTitle,
                           subTitle: item.subTitle,
                           date: Date(timeIntervalSince1970: ms / 1000),
                           eventId: item.eventId.flatMap { $0.value },
                           seriesId: item.seriesId.flatMap { $0.value })
        }
        // #1171: the feed answered with items but NONE parsed, so its shape has changed (a renamed date
        // field drops every row). Fail loud rather than hand back an empty list that would read as an empty
        // calendar. An empty feed (items itself empty) is a genuine off-season and passes through untouched.
        if !items.isEmpty && events.isEmpty { throw SourceFetchError.feedShapeChanged }
        return events
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

    // #1174: assigns a clean, run-local tag ("run-1", "run-2", ...) to each production that spans MORE
    // THAN ONE night in this document, in first-appearance order. The synthesized HTML shows that short
    // token (never the feed's opaque id) so the extractor echoes it faithfully into each night's seriesId,
    // and RunGrouping collapses those nights into one run. A production with a single night gets no tag, so
    // its article stays byte-for-byte what it was before. Run-local is enough: RunGrouping runs fresh each
    // scout, so the tag never has to be stable across runs.
    static func seriesTags(_ events: [VTEvent]) -> [String: String] {
        var counts: [String: Int] = [:]
        for e in events { if let s = e.seriesId, !s.isEmpty { counts[s, default: 0] += 1 } }
        var tags: [String: String] = [:]
        for e in events {
            guard let s = e.seriesId, !s.isEmpty, (counts[s] ?? 0) > 1, tags[s] == nil else { continue }
            tags[s] = "run-\(tags.count + 1)"
        }
        return tags
    }

    // Renders the events as one plain HTML document the extractor reads like any fetched page. Every show
    // is attributed to the venue by NAME (threaded from the source) and carries an EXPLICIT ISO date.
    // #1175: when Dan has supplied the venue's location, it is appended to each show's place line so the
    // extractor reads a real city and the geography gate places the shows in-region; with no location the
    // document is byte-for-byte what it was before, so an existing source's content hash does not churn.
    // #1174: a production that runs more than one night stamps each night with a shared `Series:` tag (see
    // seriesTags), the one signal that lets those nights collapse into a single run downstream.
    // copy-inventory:ignore-start  synthesized source HTML the extractor reads, not the app's voice (#915)
    //
    // #1529: `venueName` is OPTIONAL, and a nil one writes no place at all rather than the next best string
    // to hand (which, on the ticket-link hop that reaches this feed without a source, was the request's
    // HOSTNAME). A date stands alone as a complete row; the venue is supplied at ingest instead.
    static func listingHTML(_ events: [VTEvent], venueName: String?, location: String? = nil) -> String {
        let place = venueName.map { name in location.map { "\(name), \($0)" } ?? name }
        let tags = seriesTags(events)
        let rows = events.map { e -> String in
            let bits = [e.superTitle, e.subTitle].compactMap { $0 }.filter { !$0.isEmpty }
                .map { "<p>\($0)</p>" }.joined()
            let seriesLine = e.seriesId.flatMap { tags[$0] }.map { "<p>Series: \($0)</p>" } ?? ""
            let day = dayFormatter.string(from: e.date)
            let dateLine = place.map { "\(day) at \($0)" } ?? day
            return "<article><h2>\(e.title)</h2>\(bits)\(seriesLine)<p>\(dateLine)</p></article>"
        }.joined(separator: "\n")
        let open = venueName.map { "<section title=\"\($0)\">" } ?? "<section>"
        return "\(open)\n\(rows)\n</section>"
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

    // Reads the venue's complete upcoming list in ONE request and filters to now-or-later. `get` is
    // injected so the network is testable. A failed fetch THROWS (never an empty list): an empty list would
    // read to the reconcile as "every show was cancelled". Shared by the html and native paths below.
    static func fetchEvents(url: URL, now: Date,
                            get: (URLRequest) async throws -> Data) async throws -> [VTEvent] {
        let host = url.host ?? ""
        let data = try await get(feedRequest(forVenueHost: host))
        return upcoming(try parseEvents(data), now: now)
    }

    // Synthesizes one document from the events (the html path, still used for a one-off lead pointed at a
    // venuetix host). A failed fetch THROWS, never an empty document, for the same reconcile-safety reason.
    // #1529: the raw feed body travels back on the page, so the scout can ingest this source natively from
    // the very bytes the document (and so its hash) was built from, rather than paying to have an AI read a
    // document Overture wrote itself.
    static func fetch(url: URL, venueName: String?, location: String? = nil, now: Date,
                      get: (URLRequest) async throws -> Data) async throws -> FetchedPage {
        let data = try await get(feedRequest(forVenueHost: url.host ?? ""))
        let events = upcoming(try parseEvents(data), now: now)
        let html = PageNormalizer.normalize(listingHTML(events, venueName: venueName, location: location))
        return FetchedPage(normalizedHTML: html,
                           finalURL: url.absoluteString,
                           contentHash: PageNormalizer.contentHash(html),
                           ticketingFeedURL: url.absoluteString,
                           ticketingFeedJSON: data)
    }

    // #1237: the events mapped straight to ExtractedEvent for the native extractor. Every show is attributed
    // to the venue by NAME (threaded from the source, since the feed carries only an opaque venue id) and
    // carries Dan's supplied location (#1175). The marketing super/sub titles are not org or place data, so
    // they are deliberately dropped rather than allowed to pollute the pitchable identity.
    // #1174: only a production spanning MORE THAN ONE night here gets a shared seriesId, so those nights
    // collapse into one run downstream; a single-night show keeps a nil id so it still merges by the
    // gap-and-title walk if a sibling appears. `seriesTags` computes exactly that multi-night set, the same
    // rule the synthesized-HTML path used before the extractor echoed it back.
    // #1529: who PRESENTS and which ROOM are two different claims (see OvationTixCalendar for the case that
    // taught it). The venue is nil unless somebody with the standing to say so has said so.
    // #1680: the venue's own page for this exact night, when the feed gives both ids. The route is the one
    // the venue's own listing cards push to (`/showdetails/{seriesId}/{eventId}`), read off the live site
    // rather than guessed. Built against the SOURCE's host, since every VenueTix venue is its own subdomain
    // and the feed is a shared cloud function that names none.
    static func eventURL(for event: VTEvent, sourceURL: URL?) -> String? {
        guard let sourceURL, let host = sourceURL.host,
              let seriesId = event.seriesId, !seriesId.isEmpty,
              let eventId = event.eventId, !eventId.isEmpty else { return nil }
        return "https://\(host)/showdetails/\(seriesId)/\(eventId)"
    }

    static func extractedEvents(from events: [VTEvent], presenter: String, venue: String?,
                                location: String?, sourceURL: URL? = nil) -> [ExtractedEvent] {
        let multiNight = Set(seriesTags(events).keys)
        return events.map { e in
            ExtractedEvent(title: e.title,
                           presenter: presenter,
                           venue: venue,
                           performanceDate: dayFormatter.string(from: e.date),
                           // Dan's call (2026-07-28): a row with no per-event link falls back to the
                           // source's own calendar rather than to nothing. The card labels the two apart.
                           sourceUrl: eventURL(for: e, sourceURL: sourceURL) ?? sourceURL?.absoluteString,
                           location: location,
                           seriesId: e.seriesId.flatMap { multiNight.contains($0) ? $0 : nil })
        }
    }

    // The real network GET, shared by the html and native live readers so the status handling lives once.
    private static func liveGet(_ session: URLSession) -> (URLRequest) async throws -> Data {
        { req in
            let (data, response) = try await session.data(for: req)
            try FeedResponse.check(response)
            return data
        }
    }

    // The real network fetch as a synthesized page (the html path, used by the router).
    static func liveFetch(url: URL, venueName: String?, location: String? = nil, now: Date = Date(),
                          session: URLSession = .shared) async throws -> FetchedPage {
        try await fetch(url: url, venueName: venueName, location: location, now: now, get: liveGet(session))
    }

    // #1237: the real network fetch as STRUCTURED events, for the native extractor.
    static func liveEvents(url: URL, now: Date = Date(),
                           session: URLSession = .shared) async throws -> [VTEvent] {
        try await fetchEvents(url: url, now: now, get: liveGet(session))
    }
}
