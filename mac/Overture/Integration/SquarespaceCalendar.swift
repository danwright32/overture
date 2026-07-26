import Foundation

// #1503: Squarespace serves any page as JSON by appending `?format=json`, no key and no auth. A page
// built on its EVENTS collection carries the whole upcoming schedule as data (title, start date, venue),
// so those sources ingest natively and FREE instead of costing a paid AI extract run on every change.
// Same deal #1127 took for VenueTix and OPERA America, and deterministic and hashable for the same
// reason: these are bytes the publisher serves, not a browser render.
//
// UNLIKE those two, Squarespace is not a HOST, it is a platform serving arbitrary domains, so this
// cannot be routed by URL. Detection is by CONTENT: ask for the JSON view and use it only when the
// collection really is an events collection. Measured on Dan's watchlist 2026-07-25: 21 of 66 active
// sources are Squarespace and 7 of those are events collections; the other 14 report `index` or `page`
// and must fall through to the existing path untouched.
enum SquarespaceCalendar {
    struct SQEvent: Equatable, Sendable {
        var title: String
        var date: Date
        // Nil when the publisher named none. On a native feed that is their own blank field rather than
        // a page Overture failed to read (#1472), so the row is KEPT: Rainer Crosett's single upcoming
        // show is exactly this, and dropping it would lose a real performance.
        var venue: String?
        var url: String?
    }

    private struct Payload: Decodable {
        struct Collection: Decodable { var typeName: String? }
        struct Location: Decodable { var addressTitle: String? }
        struct Item: Decodable {
            var title: String?
            var startDate: Double?      // epoch MILLISECONDS
            var fullUrl: String?
            var location: Location?
        }
        var collection: Collection?
        var upcoming: [Item]?
    }

    // Whether this body is a Squarespace EVENTS collection. Deliberately total: anything that is not
    // JSON, not Squarespace, or not an events collection simply answers false, because the caller's
    // fallback is the existing path and a wrong "yes" would take a source off the paid read that needs
    // it. `events` and `events-stacked` are both real live values.
    static func isEventsCollection(_ data: Data) -> Bool {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let typeName = payload.collection?.typeName else { return false }
        return typeName.hasPrefix("events")
    }

    static func parseEvents(_ data: Data) throws -> [SQEvent] {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch let error as DecodingError {
            // #1184's rule: a NON-EMPTY body we could not decode is a FORMAT change, which must read
            // that way rather than as "couldn't reach that page". An empty body is genuine no-content.
            guard !data.isEmpty else { throw error }
            throw SourceFetchError.feedShapeChanged
        }
        // An events collection with nothing coming up is a real, complete answer (3 of Dan's 7 are in
        // that state today), so an absent list is empty rather than an error.
        let items = payload.upcoming ?? []

        let events: [SQEvent] = try items.map { item in
            // #1127's reconcile-safety rule, and it matters more here than anywhere: a SHORT list reads
            // to the reconcile as "the rest were cancelled" and strikes real performances. So a row
            // missing what identifies a show fails the whole read rather than being quietly skipped.
            guard let rawTitle = item.title, !rawTitle.trimmingCharacters(in: .whitespaces).isEmpty,
                  let startMilliseconds = item.startDate else {
                throw SourceFetchError.feedShapeChanged
            }
            let venue = item.location?.addressTitle
                .map(decoded)
                .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            return SQEvent(title: decoded(rawTitle),
                           date: Date(timeIntervalSince1970: startMilliseconds / 1000),
                           venue: venue,
                           url: item.fullUrl)
        }
        return events
    }

    // Squarespace serves these fields HTML-ENCODED ("Gregg Smith, Igor Stravinsky, &amp; Margaret
    // Bonds", "St. Paul &amp; St. Andrew Church"). Left alone the entity reaches Dan's pitch verbatim.
    // Reuses the decoder the extract path already applies rather than a second table of entities.
    private static func decoded(_ raw: String) -> String {
        Prospect.decodeHTMLEntities(raw)
    }

    // Unlike VenueTix and OvationTix, which are single-VENUE feeds where every show is at that venue,
    // this is an ORG's own events page: the org PRESENTS, and the venue comes from the data and varies
    // per show (Brooklyn Youth Chorus sings at Geffen Hall and at Carnegie). Naming the org as the venue
    // would put the wrong place in every pitch, and a venueless row keeps its nil rather than borrowing
    // the org's name, which would be a fabricated venue of the kind #995 and #1498 exist to prevent.
    static func extractedEvents(from events: [SQEvent], orgName: String,
                                location: String?) -> [ExtractedEvent] {
        events.map { event in
            ExtractedEvent(title: event.title,
                           presenter: orgName,
                           venue: event.venue,
                           performanceDate: dayFormatter.string(from: event.date),
                           sourceUrl: event.url,
                           location: location)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = EasternDate.calendar
        formatter.timeZone = EasternDate.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // The real network read. Asks the page for its JSON view and parses it; a non-2xx is unreachable and
    // a drifted body throws, so an empty list can never be manufactured out of a failure.
    static func liveEvents(url: URL, session: URLSession = .shared) async throws -> [SQEvent] {
        let (data, response) = try await session.data(from: jsonURL(for: url))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SourceFetchError.unreachable
        }
        return try parseEvents(data)
    }

    // The JSON view of any page, which is what detection and reading both ask for.
    static func jsonURL(for url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var queryItems = components.queryItems ?? []
        guard !queryItems.contains(where: { $0.name == "format" }) else { return url }
        queryItems.append(URLQueryItem(name: "format", value: "json"))
        components.queryItems = queryItems
        return components.url ?? url
    }
}
