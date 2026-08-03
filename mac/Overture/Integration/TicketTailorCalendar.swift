import Foundation

// #1280: the parser over a TicketTailor box-office widget (The Cell, and any all-tickets-calendar embed).
// The server-rendered widget (reached via TicketTailor.fetchWidget, #1127) embeds its events as a JS
// assignment `var selectableDates = {...};` (a map keyed by yyyy-MM-dd); each date's `event_series`
// listing the shows available that day. This parses that embedded JSON into structured events, exactly as
// VenueTixCalendar does for its JSON feed, so a TicketTailor venue ingests for FREE instead of a paid AI
// read. Unlike the host-routed OPERA/VenueTix feeds, a TicketTailor source is discovered mid-fetch (not by
// host), so this parser is handed HTML that already went through the widget hop; the read-path wiring that
// routes a detected widget here instead of to the paid read is #1295 (Phase 3).
//
// Two shapes matter, both verified against real captured bytes (2026-07-21):
//   - POPULATED: `var selectableDates = {"2026-07-21":{...,"event_series":[{"series_id":429862,
//     "name":"Beach visits","venue":"...","event_page_url":"/events/.../429862"}]}, ...};`. A recurring
//     show (one series_id) repeats under EVERY date it plays, so one row per (date, series) is correct and
//     the shared series_id is exactly RunGrouping's multi-night-run signal (Dan's decision: one card).
//   - EMPTY: `var selectableDates = [];` (an empty ARRAY, not the object map). This is The Cell's normal
//     no-events state and MUST read as a quiet empty calendar, never a shape-change failure.
enum TicketTailorCalendar {
    struct TTEvent: Equatable, Sendable {
        var name: String
        var venue: String?      // the feed's own venue text; may be absent or blank
        var date: Date
        var seriesId: String?   // TicketTailor's series_id, shared across every date a recurring show plays
        var eventURL: String?   // the event page a person would open (event_page_url, made absolute on map)
    }

    // series_id is a NUMBER in the live feed, but tolerate a string or null too so a single field's type
    // can never fail the whole parse. Mirrors VenueTixCalendar.SeriesID.
    private struct FlexID: Decodable {
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

    private struct Series: Decodable {
        let series_id: FlexID?
        let name: String?
        let venue: String?
        let event_page_url: String?
    }

    private struct DateEntry: Decodable {
        let event_series: [Series]?
    }

    // Parse the widget HTML's embedded `var selectableDates = ...;` assignment into events.
    static func parseWidget(_ html: String, zone: TimeZone = FeedDates.defaultZone) throws -> [TTEvent] {
        // No assignment at all (a non-widget page, or a shape we don't recognize) reads as empty, never an
        // error: the read-path only routes a CONFIRMED TicketTailor widget here, and a hard failure belongs
        // to the extractor's "the embed vanished" case (#1294), not to a benign parse miss.
        guard let literal = selectableDatesLiteral(in: html) else { return [] }
        let trimmed = literal.trimmingCharacters(in: .whitespacesAndNewlines)
        // The empty state is `[]` (an empty array); an empty object `{}` reads the same way. Quiet, NOT
        // drift: decoding `[]` as the event map would otherwise throw and falsely mark the venue broken.
        if trimmed.isEmpty || trimmed == "[]" || trimmed == "{}" { return [] }
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return [] }

        let map: [String: DateEntry]
        do {
            map = try JSONDecoder().decode([String: DateEntry].self, from: data)
        } catch {
            // A NON-EMPTY object we could not decode is a format change (a renamed structural field), the
            // same "fail loud" the OPERA/VenueTix guards use rather than a silent empty list.
            throw SourceFetchError.feedShapeChanged
        }

        var events: [TTEvent] = []
        var sawAnySeries = false
        for (dateKey, entry) in map {
            // #1983: Eastern, not the host zone, so the widget's day keys become the same New York days
            // the rest of Overture reckons by. The day STRING round-trips unchanged in any zone.
            guard let day = FeedDates.date(day: dateKey, zone: zone) else { continue }   // not a day
            for series in entry.event_series ?? [] {
                sawAnySeries = true
                let name = series.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !name.isEmpty, let sid = series.series_id?.value else { continue }
                let venue = series.venue?.trimmingCharacters(in: .whitespacesAndNewlines)
                events.append(TTEvent(name: name,
                                      venue: (venue?.isEmpty == false) ? venue : nil,
                                      date: day, seriesId: sid, eventURL: series.event_page_url))
            }
        }
        // Nesting-aware drift: series objects were PRESENT but not one parsed (name/series_id renamed) is a
        // shape change. "date keys present but no series anywhere" (sawAnySeries == false) is genuine
        // emptiness (a date with nothing on), which passes through as [].
        if sawAnySeries && events.isEmpty { throw SourceFetchError.feedShapeChanged }
        // Deterministic order (date, then series id) so downstream and the content hash never churn.
        return events.sorted {
            ($0.date, $0.seriesId ?? "", $0.name) < ($1.date, $1.seriesId ?? "", $1.name)
        }
    }

    // Keep shows on today or later. Day-based (the widget dates carry no time), so a show TODAY is kept
    // rather than dropped for being "before now". Filtering a COMPLETE feed to a stable rule keeps the
    // reconcile honest: a show leaves the set only once it is genuinely past.
    static func upcoming(_ events: [TTEvent], now: Date, zone: TimeZone = FeedDates.defaultZone) -> [TTEvent] {
        // #1983: Eastern's midnight, not the host clock's. At 10pm in New York a UTC host is already
        // tomorrow, and tonight's show would leave the feed, which reconcile reads as a cancellation.
        let today = FeedDates.startOfDay(now, zone: zone)
        return events.filter { FeedDates.startOfDay($0.date, zone: zone) >= today }
    }

    // The events mapped to ExtractedEvent. Dan's decisions (2026-07-21): the pitch venue is the feed's own
    // `venue` text when present, else the venue name he configured on the source; a recurring show (one
    // series_id across many dates) collapses to one card, so only a multi-date series carries its shared
    // seriesId onward (a single-date show gets nil so it is never falsely run-collapsed). The event page
    // URL is carried as the listing link a person would open.
    static func extractedEvents(from events: [TTEvent], venueName: String,
                                location: String?,
                                zone: TimeZone = FeedDates.defaultZone) -> [ExtractedEvent] {
        let multiDate = Set(seriesTags(events).keys)
        return events.map { e in
            ExtractedEvent(title: e.name,
                           presenter: venueName,
                           venue: (e.venue?.isEmpty == false) ? e.venue! : venueName,
                           performanceDate: FeedDates.day(from: e.date, zone: zone),
                           sourceUrl: e.eventURL.flatMap(absoluteEventURL),
                           location: location,
                           seriesId: e.seriesId.flatMap { multiDate.contains($0) ? $0 : nil })
        }
    }

    // The series ids that appear on MORE THAN ONE date, i.e. the recurring shows that collapse to one run.
    // Mirrors VenueTixCalendar.seriesTags' multi-night set (only the key set is used here).
    static func seriesTags(_ events: [TTEvent]) -> [String: String] {
        var counts: [String: Int] = [:]
        for e in events { if let s = e.seriesId, !s.isEmpty { counts[s, default: 0] += 1 } }
        var tags: [String: String] = [:]
        for e in events {
            guard let s = e.seriesId, !s.isEmpty, (counts[s] ?? 0) > 1, tags[s] == nil else { continue }
            tags[s] = "run-\(tags.count + 1)"
        }
        return tags
    }

    // Resolve the feed's relative event_page_url ("/events/<slug>/<id>") to an absolute tickettailor.com
    // URL a person can open; an already-absolute URL is passed through, a blank one drops out.
    private static func absoluteEventURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
        return "https://www.tickettailor.com" + (trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
    }

    // The two-hop live read, over RAW bytes: hop 1 fetches the venue page to discover the widget embed,
    // hop 2 fetches the server-rendered widget whose <script> carries the selectableDates JSON. Both hops
    // read RAW because PageNormalizer strips <script> blocks (where the JSON lives), so the paid path's
    // normalized FetchedPage cannot be reused here. `get` is injected so the network is testable.
    //
    // If the venue page loads but no longer carries an all-tickets-calendar embed (a redesign, or it was
    // never a TicketTailor venue), that THROWS feedShapeChanged, never returns []: an empty list from a
    // source that had a baseline would read to the reconcile as every stored show cancelled (#887/#897).
    static func liveEvents(pageURL: URL, now: Date,
                           get: (URLRequest) async throws -> Data) async throws -> [TTEvent] {
        let pageHTML = decode(try await get(pageRequest(pageURL)))
        guard let widget = TicketTailor.widgetURL(inPage: pageHTML) else {
            throw SourceFetchError.feedShapeChanged
        }
        let widgetHTML = decode(try await get(TicketTailor.widgetRequest(widget)))
        return upcoming(try parseWidget(widgetHTML), now: now)
    }

    // The real network variant. A non-2xx on either hop THROWS (never an empty list), for the same
    // reconcile-safety reason.
    static func liveEvents(pageURL: URL, now: Date = Date(),
                           session: URLSession = .shared) async throws -> [TTEvent] {
        try await liveEvents(pageURL: pageURL, now: now, get: { req in
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw SourceFetchError.unreachable }
            guard (200..<300).contains(http.statusCode) else { throw SourceFetchError.http(http.statusCode) }
            return data
        })
    }

    // copy-inventory:ignore-start  an outbound fetch's headers for the venue page hop, not the app's voice (#915)
    private static func pageRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36",
                     forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        return req
    }
    // copy-inventory:ignore-end

    private static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    // #1301: the raw `var selectableDates = ...;` literal, used as the change signal for the widget's
    // content hash. The normalized HTML the fetcher would otherwise hash drops the <script> this lives in,
    // keeping only the events-filter <option> list (one per distinct show), so a normalized hash moves when
    // the SET of shows changes but NOT when an already-listed recurring show merely gains a new date. This
    // literal moves on either. Returns nil when the marker is absent (a shell, an unrecognized shape), so
    // the caller can fall back to the normalized hash. Over-reading on cosmetic JSON churn is acceptable:
    // a TicketTailor re-read parses natively for free (#1295), whereas missing new dates is a real miss.
    static func selectableDatesSignal(in html: String) -> String? {
        selectableDatesLiteral(in: html)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Extract the value of `var selectableDates = <value>;` from the widget HTML by balancing braces and
    // brackets (respecting string literals), NOT by reading to the first `;` (a venue or title string can
    // legitimately contain `;`, `{`, or `}`, which a naive scan would truncate on).
    private static func selectableDatesLiteral(in html: String) -> String? {
        // copy-inventory:ignore-start  a search marker for the widget's JS assignment, not the app's voice (#915)
        guard let marker = html.range(of: "var selectableDates = ") else { return nil }
        // copy-inventory:ignore-end
        return balancedLiteral(html[marker.upperBound...])
    }

    private static func balancedLiteral<S: StringProtocol>(_ s: S) -> String? {
        var depth = 0, started = false, inString = false, escaped = false
        var result = ""
        for ch in s {
            if !started {
                if ch == "{" || ch == "[" { started = true }
                else if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" { continue }
                else { return nil }   // not a JSON value after the marker
            }
            result.append(ch)
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 { return result }
            default: break
            }
        }
        return started ? result : nil   // unterminated: hand back what we have (decode fails -> handled)
    }
}
