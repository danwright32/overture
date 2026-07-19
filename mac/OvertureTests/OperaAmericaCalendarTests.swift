import Testing
import Foundation
@testable import Overture

// #1127: OPERA America's calendar is a JavaScript app whose events load from a public Umbraco feed
// (`POST /umbraco/surface/calendar/filtered`). A plain fetch of the page reads as "readable" (a text-rich
// shell) but carries no events, so the scout's rescue never fires and the source silently yields nothing.
// The adapter reads that feed directly. These tests pin the pure parse of a REAL feed page (captured live
// 2026-07-18), so the mapping from the platform's JSON to Overture's events is grounded in the real shape,
// not a guess.
@Suite("OPERA America calendar feed adapter")
struct OperaAmericaCalendarTests {
    // A real two-item slice of `POST /umbraco/surface/calendar/filtered` (page 1), fields trimmed to what
    // the adapter reads. Keeps the envelope (currentPage/totalPages/totalItems/itemsPerPage) the pagination
    // relies on, and a null `venue` (Glimmerglass) alongside a present one (Norton Hall), because the feed
    // really does omit venue for some items.
    static let feedPage1 = #"""
    {
      "currentPage": 1,
      "totalPages": 30,
      "totalItems": 357,
      "itemsPerPage": 12,
      "items": [
        {
          "itemType": "Opera Performance", "id": 23443, "title": "Fellow Travelers",
          "company": "Glimmerglass Festival", "date": "2026-07-18T00:00:00", "time": "1:00 PM",
          "venue": null, "city": "Cooperstown", "state": "NY",
          "eventLink": "http://www.glimmerglass.org", "composer": " Gregory Spears",
          "url": "/calendar/opera performance/23443/fellow-travelers"
        },
        {
          "itemType": "Opera Performance", "id": 23618, "title": "Die Zauberflöte",
          "company": "Chautauqua Opera", "date": "2026-07-18T00:00:00", "time": "2:00 PM",
          "venue": "Norton Hall", "city": "Chautauqua", "state": "NY",
          "eventLink": "http://www.opera.chq.org", "composer": " Wolfgang Mozart",
          "url": "/calendar/opera performance/23618/die-zauberflote"
        }
      ]
    }
    """#

    @Test func parsesTheFeedPageIntoEvents() throws {
        let page = try OperaAmericaCalendar.parsePage(Data(Self.feedPage1.utf8))

        #expect(page.totalPages == 30)
        #expect(page.totalItems == 357)
        #expect(page.events.count == 2)

        let first = page.events[0]
        #expect(first.title == "Fellow Travelers")
        #expect(first.company == "Glimmerglass Festival")
        #expect(first.city == "Cooperstown")
        #expect(first.state == "NY")
        #expect(first.venue == nil)                       // the feed really omits venue here
        #expect(first.eventLink == "http://www.glimmerglass.org")
        // Date parsed to a real Date, not a raw string, so a horizon/geography filter can reason about it.
        let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: first.date)
        #expect(comps.year == 2026 && comps.month == 7 && comps.day == 18)

        #expect(page.events[1].title == "Die Zauberflöte")
        #expect(page.events[1].venue == "Norton Hall")
    }

    // The adapter hands the rest of the pipeline a normal HTML document (like the multi-month stitch does),
    // so the extractor and the content hash work unchanged. Each event must render its own title, company,
    // an explicit ISO date (the Bargemusic lesson: never leave a date implied), venue/city/state, and the
    // ticket link, so the reader can pull a real listing out of it.
    // #1171: the Umbraco feed is undocumented and will change shape eventually. A page that answers with
    // items whose fields have been renamed parses to zero events, which would make the source read as empty
    // rather than broken. When items are present but NONE parse, that is drift, so fail loud.
    @Test func parsingThrowsWhenItemsArePresentButNoneParse() throws {
        // A page that reports items but whose date field was renamed (eventDate instead of date): every row
        // fails to parse, from a non-empty item list. That is a shape change, not an empty calendar.
        let drifted = #"""
        {
          "currentPage": 1, "totalPages": 1, "totalItems": 1, "itemsPerPage": 12,
          "items": [ { "title": "A Show", "company": "Some Opera", "eventDate": "2026-07-18T00:00:00" } ]
        }
        """#
        #expect(throws: SourceFetchError.feedShapeChanged) {
            _ = try OperaAmericaCalendar.parsePage(Data(drifted.utf8))
        }
    }

    // A genuinely empty page (nothing in range) is NOT drift: zero items parse to zero events, and that must
    // stay a normal quiet result, never a failure.
    @Test func parsingAnEmptyPageIsNotTreatedAsDrift() throws {
        let empty = #"{ "currentPage": 1, "totalPages": 1, "totalItems": 0, "itemsPerPage": 12, "items": [] }"#
        let page = try OperaAmericaCalendar.parsePage(Data(empty.utf8))
        #expect(page.events.isEmpty)
    }

    @Test func synthesizesAReadableDeterministicDocument() throws {
        let events = try OperaAmericaCalendar.parsePage(Data(Self.feedPage1.utf8)).events
        let html = OperaAmericaCalendar.listingHTML(events)

        for needle in ["Fellow Travelers", "Glimmerglass Festival", "2026-07-18", "Cooperstown",
                       "http://www.glimmerglass.org", "Die Zauberflöte", "Norton Hall", "Chautauqua"] {
            #expect(html.contains(needle), "listing HTML is missing \(needle)")
        }
        // Deterministic: the same events must always render identical bytes, or the content hash churns and
        // the "skip unchanged sources" saving collapses.
        #expect(OperaAmericaCalendar.listingHTML(events) == html)
    }

    // A one-event page, `page` of `total`, for the pagination tests.
    private static func page(_ page: Int, of total: Int, title: String) -> Data {
        Data(#"""
        {"currentPage":\#(page),"totalPages":\#(total),"totalItems":\#(total),"itemsPerPage":1,
         "items":[{"title":"\#(title)","company":"Co","date":"2026-08-01T19:00:00","venue":null,
                   "city":"New York","state":"NY","eventLink":"https://x.test"}]}
        """#.utf8)
    }

    @Test func fetchCollectsEveryPageIntoOneDocument() async throws {
        let url = URL(string: "https://www.operaamerica.org/calendar/")!
        let result = try await OperaAmericaCalendar.fetch(url: url) { p in
            Self.page(p, of: 3, title: "Show \(p)")
        }
        // All three pages' events land in the one document (finalURL is the watched page, hash is real).
        #expect(result.normalizedHTML.contains("Show 1"))
        #expect(result.normalizedHTML.contains("Show 2"))
        #expect(result.normalizedHTML.contains("Show 3"))
        #expect(result.finalURL == url.absoluteString)
        #expect(!result.contentHash.isEmpty)
    }

    // THE reconcile-safety guarantee: if any page fails, the whole fetch throws. It must NEVER return the
    // pages it did get as if that were the complete list, because a short list reads to the reconcile as
    // "the missing shows were cancelled" and would strike real performances.
    @Test func fetchThrowsRatherThanReturningAPartialListWhenAPageFails() async throws {
        struct PageError: Error {}
        let url = URL(string: "https://www.operaamerica.org/calendar/")!
        await #expect(throws: PageError.self) {
            _ = try await OperaAmericaCalendar.fetch(url: url) { p in
                if p == 1 { return Self.page(1, of: 4, title: "Show 1") }
                throw PageError()   // page 2 of 4 fails
            }
        }
    }

    // #1183: the OPERA feed window must be the SHARED calendar horizon, not a private copy of "4 months",
    // so if the horizon ever changes the feed cannot silently keep requesting four months and drift from
    // the rest of the scout.
    @Test func theFeedWindowIsTheSharedCalendarHorizon() {
        let now = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 7, day: 18))!
        let end = OperaAmericaCalendar.windowEnd(from: now)
        let months = Calendar.current.dateComponents([.month], from: now, to: end).month
        #expect(months == CalendarMonthIndex.defaultHorizon)
    }

    @Test func handlesOperaAmericaHostsOnly() {
        #expect(OperaAmericaCalendar.handles(URL(string: "https://www.operaamerica.org/calendar/")!))
        #expect(OperaAmericaCalendar.handles(URL(string: "https://operaamerica.org/")!))
        #expect(!OperaAmericaCalendar.handles(URL(string: "https://www.thecelltheatre.org/box-office")!))
        #expect(!OperaAmericaCalendar.handles(URL(string: "https://operaamerica.org.evil.com/")!))
    }

    @Test func theFilteredRequestCarriesTheDateRangeAndPage() throws {
        let from = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 7, day: 18))!
        let to = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 18))!
        let req = OperaAmericaCalendar.filteredRequest(host: "www.operaamerica.org", from: from, to: to,
                                                       page: 2, pageSize: 100)
        #expect(req.url?.absoluteString == "https://www.operaamerica.org/umbraco/surface/calendar/filtered")
        #expect(req.httpMethod == "POST")
        let body = req.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(body.contains("2026-07-18"))
        #expect(body.contains("2026-11-18"))
        #expect(body.contains("\"page\":2"))
        #expect(body.contains("\"pageSize\":100"))
    }

    // #1170: the feed defaults to the national calendar (350+ upcoming), a large document the extractor
    // reads every time it changes. The feed accepts a `states` filter (verified live: state CODES, not
    // full names), so we request exactly the geography gate's in-range set up front. It must match that set
    // (EventPlace.inRangeStates = ny/nj/ct) so it can never narrow harder than the gate and drop a
    // NYC-metro show sitting in NJ or CT.
    @Test func theFilteredRequestNarrowsToTheInRangeStates() throws {
        let from = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 7, day: 18))!
        let to = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 18))!
        let req = OperaAmericaCalendar.filteredRequest(host: "www.operaamerica.org", from: from, to: to,
                                                       page: 1, pageSize: 100)
        let body = req.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(body.contains("\"states\":[\"NY\",\"NJ\",\"CT\"]"))
    }

    @Test func sourceFetcherRoutesOperaUrlsToTheAdapter() async throws {
        let opera = URL(string: "https://www.operaamerica.org/calendar/")!
        let stub = FetchedPage(normalizedHTML: "OPERA-STUB", finalURL: opera.absoluteString, contentHash: "h")
        let out = try await SourceFetcher.fetch(opera, operaFeed: { _ in stub })
        #expect(out.normalizedHTML == "OPERA-STUB")
    }
}
