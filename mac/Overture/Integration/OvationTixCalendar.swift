import Foundation

// #1344: SoHo Playhouse (and any *.ovationtix.com venue) is an OvationTix / AudienceView single-page app; a
// plain fetch reads as a ~2.4 KB shell with no events, so the source went down the paid AI-read path. Its
// calendar loads from a public JSON feed the SPA calls, `GET web.ovationtix.com/trs/api/rest/
// CalendarProductions`, scoped to the venue by a `clientId` REQUEST HEADER (the numeric id in the venue's own
// URL path, e.g. 35583 in ci.ovationtix.com/35583). The response is a date-keyed array: each day lists the
// productions playing that day. Reading it is deterministic and hashable, so unlike a browser render it is
// safe for the content hash and the reconcile. The venue NAME and CITY are not in the feed, so both are
// threaded in from the WatchedSource (orgName + venueLocation), exactly as the VenueTix adapter does.
enum OvationTixCalendar {
    struct OTEvent: Equatable, Sendable {
        var title: String
        var superTitle: String?
        var subTitle: String?
        var date: Date
        // The feed's own production id, shared by every day of one run (a run that plays several nights lists
        // the same productionId under each of its dates). It is the authoritative "these dates are one
        // production" signal and does not depend on titles matching or nights being close together. For any
        // production that spans MORE THAN ONE day in a document, listingHTML stamps each of its dates with a
        // shared `Series:` tag the extractor copies into the event's seriesId, and RunGrouping collapses those
        // dates into one run. Nil when the feed names none.
        var seriesId: String? = nil
        // #1680: the ids that address the venue's own page for THIS night. `productionId` is the same value
        // seriesId carries; kept separately because seriesId is deliberately blanked for a single-night show
        // (so it never wrongly collapses a run) and the link must survive that.
        var productionId: String? = nil
        var performanceId: String? = nil
        // #1984: EVERY start time this production plays on this day, in the order the feed lists them,
        // as "HH:mm". Empty when the feed named none, which must stay distinguishable from a day that
        // starts at midnight.
        //
        // A LIST, not one value, because a production really can play twice on one day: measured live
        // 2026-08-02 across both watched OvationTix venues, 24 of 274 visible rows carry two showtimes
        // (a 5:00 PM and 9:15 PM double bill; Alice in Wonderland at 11:00 AM and 2:00 PM). The adapter
        // used to take `showtimes.first` and the second performance vanished with nothing recording it.
        // The row stays ONE row (Dan pitches a production once); what it must not do is state one of the
        // two times as if it were the day's only one.
        var startTimes: [String] = []
    }

    // One day of the calendar: the ISO day plus the productions playing it.
    private struct DateGroup: Decodable {
        var date: String
        var productions: [Production]
    }

    // A production playing on a day. `name` is the identity and is required; a renamed/removed name key makes
    // the decode throw, which parseEvents maps to the clear "format has probably changed" reason. Everything
    // else is tolerant: `productionId` is optional so a single row's missing/retyped id never fails the whole
    // parse (it simply yields no series id), and `hidden` is optional (absent means visible).
    private struct Production: Decodable {
        var productionId: Int?
        var name: String
        var supertitle: String?
        var subtitle: String?
        var hidden: Bool?
        // #1680: the performances of this production ON THIS DAY (the feed repeats a production under each
        // of its dates and lists only that date's showtimes). Optional throughout, so a feed that ever omits
        // it costs the link and never the row.
        var showtimes: [Showtime]?
    }

    private struct Showtime: Decodable {
        var performanceId: Int?
        // #1984: the feed states each performance's start as "yyyy-MM-dd HH:mm" ("2026-07-29 19:00").
        // Optional like everything else here, so a feed that drops or renames it costs the TIME and never
        // the row: a show is real and pitchable whether or not its clock survived the read.
        var performanceStartTime: String?
    }

    // The "HH:mm" of a showtime that genuinely belongs to `day`, or nil.
    //
    // The stated day must MATCH the day the showtime is filed under. The two are separate assertions by
    // the feed and can only disagree if something drifted, and a time relabelled onto the wrong date is
    // worse than no time: it would be read as this day's curtain and could quiet the double-booking
    // warning on a night that is not clear. Anything that is not exactly "yyyy-MM-dd HH:mm" in 24-hour
    // form yields nil rather than a guess.
    static func startTime(_ raw: String?, on day: String) -> String? {
        guard let raw else { return nil }
        let parts = raw.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, String(parts[0]) == day else { return nil }
        let time = String(parts[1])
        let digits = Array(time)
        guard digits.count == 5, digits[2] == ":",
              let hour = Int(String(digits[0...1])), let minute = Int(String(digits[3...4])),
              digits[0].isNumber, digits[1].isNumber, digits[3].isNumber, digits[4].isNumber,
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return time
    }

    static func parseEvents(_ data: Data, zone: TimeZone = FeedDates.defaultZone) throws -> [OTEvent] {
        let groups: [DateGroup]
        do {
            groups = try JSONDecoder().decode([DateGroup].self, from: data)
        } catch let error as DecodingError {
            // A NON-EMPTY body we could not decode is a FORMAT change (a required field like `name` drifted),
            // and must read the same clear "format has probably changed" way as the all-dropped guard below,
            // not the misleading "couldn't reach that page" a raw DecodingError maps to. An empty body is
            // genuine no-content, so it keeps its original error.
            guard !data.isEmpty else { throw error }
            throw SourceFetchError.feedShapeChanged
        }
        var events: [OTEvent] = []
        // Non-hidden productions we ATTEMPTED to surface. If the feed carried visible rows but none produced a
        // dated event (a renamed date value drops every row), that is drift, not an empty calendar.
        var visibleRows = 0
        for group in groups {
            // #1983: the feed's dates are day-granular, and reading them in Eastern (rather than the
            // Mac's own zone) yields the same New York midnight the rest of Overture reckons by. The day
            // STRING round-trips unchanged in any zone, so no source's content hash churns for this.
            let day = FeedDates.date(day: group.date, zone: zone)
            for production in group.productions where production.hidden != true {
                visibleRows += 1
                let title = production.name.trimmingCharacters(in: .whitespacesAndNewlines)
                // A row we cannot date, or that names nothing, is not a listing we can pitch or reconcile, so
                // drop it rather than invent one. Every real row has carried both, so this is a guard.
                guard let day, !title.isEmpty else { continue }
                events.append(OTEvent(title: title,
                                      superTitle: nonEmpty(production.supertitle),
                                      subTitle: nonEmpty(production.subtitle),
                                      date: day,
                                      seriesId: production.productionId.map(String.init),
                                      productionId: production.productionId.map(String.init),
                                      performanceId: production.showtimes?
                                          .compactMap(\.performanceId).first.map(String.init),
                                      // #1984: EVERY performance this production plays today, in feed
                                      // order. `first` above still addresses the link, which is a
                                      // separate question: a link opens the production's page for the
                                      // day and shows both, while a single time would CLAIM the day
                                      // starts then.
                                      startTimes: (production.showtimes ?? [])
                                          .compactMap { startTime($0.performanceStartTime, on: group.date) }))
            }
        }
        // The feed answered with visible productions but NONE parsed, so its shape has changed. Fail loud
        // rather than hand back an empty list that would read as an empty calendar. A feed that is genuinely
        // empty (no groups) or all-hidden (nothing public to pitch) parses to zero from zero and passes
        // through untouched, staying a normal quiet result.
        if visibleRows > 0 && events.isEmpty { throw SourceFetchError.feedShapeChanged }
        return events
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    // Keep shows on today's day or later; a show whose day is already past cannot be pitched. The feed is
    // day-granular, so a show playing TODAY stays kept even in the afternoon (comparing against the start of
    // now's day, not the current instant). Filtering a COMPLETE feed to a stable rule keeps the reconcile
    // honest: a show leaves the set only once its day is genuinely past, never because a partial read shrank
    // the list.
    static func upcoming(_ events: [OTEvent], now: Date, zone: TimeZone = FeedDates.defaultZone) -> [OTEvent] {
        // #1983: Eastern's midnight, not the host clock's. At 10pm in New York a UTC host is already
        // tomorrow, and every show playing tonight would leave the feed, which the reconcile then reads
        // as those shows having been cancelled.
        let today = FeedDates.startOfDay(now, zone: zone)
        return events.filter { $0.date >= today }
    }

    // Assigns a clean, run-local tag ("run-1", "run-2", ...) to each production that spans MORE THAN ONE day
    // in this document, in first-appearance order. The synthesized HTML shows that short token (never the
    // feed's opaque id) so the extractor echoes it faithfully into each date's seriesId and RunGrouping
    // collapses those dates into one run. A production with a single day gets no tag, so its article stays
    // byte-for-byte what it was before. Run-local is enough: RunGrouping runs fresh each scout.
    static func seriesTags(_ events: [OTEvent]) -> [String: String] {
        var counts: [String: Int] = [:]
        for e in events { if let s = e.seriesId, !s.isEmpty { counts[s, default: 0] += 1 } }
        var tags: [String: String] = [:]
        for e in events {
            guard let s = e.seriesId, !s.isEmpty, (counts[s] ?? 0) > 1, tags[s] == nil else { continue }
            tags[s] = "run-\(tags.count + 1)"
        }
        return tags
    }

    // Renders the events as one plain HTML document the extractor reads like any fetched page. Every show is
    // attributed to the venue by NAME (threaded from the source, since the feed carries no venue name) and
    // carries an EXPLICIT ISO date. When Dan has supplied the venue's location it is appended to each show's
    // place line so the extractor reads a real city and the geography gate places the shows in-region; with no
    // location the document is byte-for-byte what it was before, so an existing source's hash does not churn.
    // A production that runs more than one day stamps each of its dates with a shared `Series:` tag (see
    // seriesTags), the one signal that lets those dates collapse into a single run downstream.
    // copy-inventory:ignore-start  synthesized source HTML the extractor reads, not the app's voice (#915)
    //
    // #1529: `venueName` is OPTIONAL, and a nil one writes no place at all rather than the next best string
    // to hand. It is nil on exactly one path (the ticket-link hop, which reaches this feed without a source),
    // and the next best string there was the request's HOSTNAME, which cost The Players Theatre all 149 of
    // its shows. The date still stands alone as a complete row; the venue is supplied at ingest instead.
    static func listingHTML(_ events: [OTEvent], venueName: String?, location: String? = nil,
                            zone: TimeZone = FeedDates.defaultZone) -> String {
        let place = venueName.map { name in location.map { "\(name), \($0)" } ?? name }
        let tags = seriesTags(events)
        let rows = events.map { e -> String in
            let bits = [e.superTitle, e.subTitle].compactMap { $0 }.filter { !$0.isEmpty }
                .map { "<p>\($0)</p>" }.joined()
            let seriesLine = e.seriesId.flatMap { tags[$0] }.map { "<p>Series: \($0)</p>" } ?? ""
            let day = FeedDates.day(from: e.date, zone: zone)
            let dateLine = place.map { "\(day) at \($0)" } ?? day
            return "<article><h2>\(e.title)</h2>\(bits)\(seriesLine)<p>\(dateLine)</p></article>"
        }.joined(separator: "\n")
        let open = venueName.map { "<section title=\"\($0)\">" } ?? "<section>"
        return "\(open)\n\(rows)\n</section>"
    }
    // copy-inventory:ignore-end

    // The OvationTix calendar feed. Fixed endpoint; the venue is chosen by the `clientId` request header.
    private static let feedURL = "https://web.ovationtix.com/trs/api/rest/CalendarProductions"

    // True for any *.ovationtix.com host (each venue is a numeric path under ci.ovationtix.com; the API lives
    // on web.ovationtix.com). Suffix match so a look-alike like `ovationtix.com.evil.com` or
    // `evilovationtix.com` never routes here.
    static func handles(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "ovationtix.com" || host.hasSuffix(".ovationtix.com")
    }

    // The venue's numeric client id, read out of the URL path (ci.ovationtix.com/35583 -> "35583"). The feed
    // is scoped to a venue ONLY by this id, so it is the one thing the request must carry.
    static func clientId(from url: URL) -> String? {
        url.pathComponents.first { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    // copy-inventory:ignore-start  an outbound API request scoped by a header, not the app's voice (#915)
    static func feedRequest(clientId: String) -> URLRequest {
        var req = URLRequest(url: URL(string: feedURL)!)
        // The feed returns HTTP 400 ("Required request header 'clientId' ... is not present") without this
        // header; a query param is ignored. It is the only header the endpoint requires.
        req.setValue(clientId, forHTTPHeaderField: "clientId")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36",
                     forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        return req
    }
    // copy-inventory:ignore-end

    // Reads the venue's complete upcoming calendar in ONE request and filters to today-or-later. `get` is
    // injected so the network is testable. A missing client id (a url that could not be scoped to a venue) or
    // a failed fetch THROWS, never an empty list: an empty list would read to the reconcile as "every show
    // was cancelled". Shared by the html and native paths below.
    static func fetchEvents(url: URL, now: Date,
                            get: (URLRequest) async throws -> Data) async throws -> [OTEvent] {
        guard let clientId = clientId(from: url) else { throw SourceFetchError.addressUnusable }
        let data = try await get(feedRequest(clientId: clientId))
        return upcoming(try parseEvents(data), now: now)
    }

    // Synthesizes one document from the events (the html path, still used for a one-off lead pointed at an
    // ovationtix host). A failed fetch THROWS, never an empty document, for the same reconcile-safety reason.
    // #1529: the raw feed body travels back on the page. It is what lets the scout ingest this source
    // natively from the very bytes this document (and so its hash) was built from, instead of paying to
    // have an AI read a document Overture wrote itself.
    static func fetch(url: URL, venueName: String?, location: String? = nil, now: Date,
                      get: (URLRequest) async throws -> Data) async throws -> FetchedPage {
        guard let clientId = clientId(from: url) else { throw SourceFetchError.addressUnusable }
        let data = try await get(feedRequest(clientId: clientId))
        let events = upcoming(try parseEvents(data), now: now)
        let html = PageNormalizer.normalize(listingHTML(events, venueName: venueName, location: location))
        return FetchedPage(normalizedHTML: html,
                           finalURL: url.absoluteString,
                           contentHash: PageNormalizer.contentHash(html),
                           ticketingFeedURL: url.absoluteString,
                           ticketingFeedJSON: data)
    }

    // The events mapped straight to ExtractedEvent for the native extractor. Every show is attributed to the
    // venue by NAME (threaded from the source, since the feed carries no venue name) and carries Dan's
    // supplied location. The marketing SUBtitle is not org or place data, so it is deliberately dropped
    // rather than allowed to pollute the pitchable identity. Only a production spanning MORE THAN ONE
    // day here keeps a seriesId, so those dates collapse into one run downstream; a single-day show keeps a
    // nil id so it still merges by the gap-and-title walk if a sibling appears.
    //
    // #1529: who PRESENTS and which ROOM are two different claims, and only the second one can be wrong in
    // a way nothing downstream can catch. The presenter is whoever's calendar this is; the venue is nil
    // unless somebody with the standing to say so has said so (Dan pointed at the venue's own feed, or
    // named the room himself). A nil venue drops the row, which is the right answer over a guessed one.
    // #1680: the venue's own page for this night. The shape is the one already observed in Dan's store for
    // another OvationTix venue (written there by the AI read path), so it is copied rather than invented.
    // The performanceId is what distinguishes one night of a run from another; without it every night of a
    // run would link to the same page, which is the difference between a link and a useful one.
    static func eventURL(for event: OTEvent, sourceURL: URL?) -> String? {
        guard let sourceURL, let clientId = clientId(from: sourceURL),
              let productionId = event.productionId, !productionId.isEmpty else { return nil }
        let base = "https://ci.ovationtix.com/\(clientId)/production/\(productionId)"
        guard let performanceId = event.performanceId, !performanceId.isEmpty else { return base }
        return base + "?performanceId=\(performanceId)"
    }

    static func extractedEvents(from events: [OTEvent], presenter: String, venue: String?,
                                location: String?, sourceURL: URL? = nil,
                                zone: TimeZone = FeedDates.defaultZone) -> [ExtractedEvent] {
        let multiNight = Set(seriesTags(events).keys)
        return events.map { e in
            ExtractedEvent(title: e.title,
                           // #2452: the company this production credits above its own title, when it
                           // credits one, rather than the room every show here shares. This field used to
                           // reach the native path and be discarded, while the VenueTix adapter read the
                           // identical field as a producer: one concept, two readings, each file correct
                           // on its own (L89). Both OvationTix rooms on the watchlist produce rows with
                           // nobody to pitch (SoHo Playhouse 21 live shows, The Players Theatre 15,
                           // measured on the live store 2026-08-10), because a presenter that is only the
                           // room's own name is drained downstream and leaves no organisation at all.
                           //
                           // Through the shared rule, so a marketing supertitle ("For One Night Only")
                           // still falls through to the room here exactly as it does there.
                           presenter: ProducerShapedName.presenter(creditedAbove: e.superTitle,
                                                                   orElse: presenter),
                           venue: venue,
                           performanceDate: FeedDates.day(from: e.date, zone: zone),
                           // Dan's call (2026-07-28): fall back to the venue's own calendar, never nothing.
                           sourceUrl: eventURL(for: e, sourceURL: sourceURL) ?? sourceURL?.absoluteString,
                           location: location,
                           seriesId: e.seriesId.flatMap { multiNight.contains($0) ? $0 : nil },
                           // #1984: every performance of this production TODAY, not just the first. The
                           // link above still addresses one of them, which is a different question: a
                           // link opens a page listing both, a single time would claim the day starts then.
                           startTimes: e.startTimes)
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

    // The real network fetch as a synthesized page (the html path, used by the router for a one-off lead).
    static func liveFetch(url: URL, venueName: String?, location: String? = nil, now: Date = Date(),
                          session: URLSession = .shared) async throws -> FetchedPage {
        try await fetch(url: url, venueName: venueName, location: location, now: now, get: liveGet(session))
    }

    // The real network fetch as STRUCTURED events, for the native extractor.
    static func liveEvents(url: URL, now: Date = Date(),
                           session: URLSession = .shared) async throws -> [OTEvent] {
        try await fetchEvents(url: url, now: now, get: liveGet(session))
    }
}
