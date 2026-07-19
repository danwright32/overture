import Testing
import Foundation
@testable import Overture

// #1127: Green Room 42 is a VenueTix single-page app; a plain fetch reads as a shell showing "0 Events",
// so the source silently yields nothing. Its events actually load from a public VenueTix cloud-function
// feed (`/clientApi/client/nine-events`, which despite its name returns the COMPLETE upcoming list, scoped
// to the venue by the request's Origin/Referer subdomain). This adapter reads that feed directly.
// These tests pin the parse of a REAL feed slice (captured live 2026-07-18) and the date filtering.
@Suite("VenueTix calendar feed adapter")
struct VenueTixCalendarTests {
    // Two real events from `nine-events`, real field names. `dateTime` is epoch MILLISECONDS.
    static let feed = #"""
    [
      {"eventId":"a1","seriesId":"s1","title":"Luigi: The Musical",
       "superTitle":"The sell out musical direct from San Francisco hits NYC!",
       "subTitle":"A tale of love, murder and hashbrowns","dateTime":1781832600000,
       "weekDay":"Thursday","venue":"nPzwjAe1WSbF8IynPUAx"},
      {"eventId":"a2","seriesId":"s2","title":"The Ethel Merman Disco Album Project",
       "superTitle":"Disco Diva Does Merman","subTitle":"Carly Ozard and Friends",
       "dateTime":1781910000000,"weekDay":"Friday","venue":"nPzwjAe1WSbF8IynPUAx"}
    ]
    """#

    @Test func parsesTheFeedIntoDatedEvents() throws {
        let events = try VenueTixCalendar.parseEvents(Data(Self.feed.utf8))

        #expect(events.count == 2)
        let first = events[0]
        #expect(first.title == "Luigi: The Musical")
        #expect(first.subTitle == "A tale of love, murder and hashbrowns")
        #expect(first.superTitle == "The sell out musical direct from San Francisco hits NYC!")
        // dateTime is epoch milliseconds, so the parsed Date is exactly that instant.
        #expect(first.date == Date(timeIntervalSince1970: 1_781_832_600))
        #expect(events[1].title == "The Ethel Merman Disco Album Project")
    }

    // The synthesized document attributes every show to the venue by NAME (threaded from the source, since
    // the feed carries only an opaque venue id), gives each an explicit ISO date, and is deterministic.
    @Test func synthesizesADocumentAttributedToTheVenue() throws {
        let events = try VenueTixCalendar.parseEvents(Data(Self.feed.utf8))
        let html = VenueTixCalendar.listingHTML(events, venueName: "The Green Room 42")

        for needle in ["The Green Room 42", "Luigi: The Musical", "A tale of love, murder and hashbrowns",
                       "The Ethel Merman Disco Album Project"] {
            #expect(html.contains(needle), "listing HTML is missing \(needle)")
        }
        #expect(VenueTixCalendar.listingHTML(events, venueName: "The Green Room 42") == html)  // deterministic
    }

    // Past shows are dropped (they cannot be pitched); everything today-or-later is kept. Filtering a
    // COMPLETE feed to a stable window keeps the reconcile honest: a show only leaves the set once it is
    // genuinely past, never because a partial read shrank the list.
    @Test func keepsOnlyUpcomingShows() throws {
        let past = VenueTixCalendar.VTEvent(title: "Yesterday", superTitle: nil, subTitle: nil,
                                            date: Date(timeIntervalSince1970: 1_000))
        let future = VenueTixCalendar.VTEvent(title: "Tomorrow", superTitle: nil, subTitle: nil,
                                              date: Date(timeIntervalSince1970: 5_000))
        let now = Date(timeIntervalSince1970: 2_000)
        let kept = VenueTixCalendar.upcoming([past, future], now: now)
        #expect(kept.map(\.title) == ["Tomorrow"])
    }

    // #1171: an undocumented public feed will change shape eventually. A feed that answers with items but
    // whose fields have been renamed parses to zero events, which would make the source read as empty
    // rather than broken. When the feed carried items but NONE parsed, that is drift, so fail loud.
    @Test func parsingThrowsWhenTheFeedHasItemsButNoneParse() throws {
        // A real-shaped array whose date field was renamed (dateTimeMs instead of dateTime): every row
        // fails to parse, from a non-empty feed. That is a shape change, not an empty calendar.
        let drifted = #"[{"title":"A Show","dateTimeMs":1781832600000},{"title":"Another","dateTimeMs":1781910000000}]"#
        #expect(throws: SourceFetchError.feedShapeChanged) {
            _ = try VenueTixCalendar.parseEvents(Data(drifted.utf8))
        }
    }

    // A genuinely empty feed (the venue has nothing loaded) is NOT drift: it parses to zero from zero, and
    // must stay a normal quiet result, never a failure.
    @Test func parsingAnEmptyFeedIsNotTreatedAsDrift() throws {
        let empty = try VenueTixCalendar.parseEvents(Data("[]".utf8))
        #expect(empty.isEmpty)
    }

    @Test func handlesVenuetixSubdomainsOnly() {
        #expect(VenueTixCalendar.handles(URL(string: "https://thegreenroom42.venuetix.com/")!))
        #expect(!VenueTixCalendar.handles(URL(string: "https://venuetix.com.evil.com/")!))
        #expect(!VenueTixCalendar.handles(URL(string: "https://evilvenuetix.com/")!))
        #expect(!VenueTixCalendar.handles(URL(string: "https://www.operaamerica.org/")!))
    }

    // The feed is scoped to the venue ONLY by the request's Origin/Referer subdomain (without them it
    // returns "Unauthorized access"), so the adapter must send the venue's own subdomain.
    @Test func theFeedRequestIsScopedToTheVenueSubdomain() {
        let req = VenueTixCalendar.feedRequest(forVenueHost: "thegreenroom42.venuetix.com")
        #expect(req.url?.absoluteString.contains("venuetixprod.cloudfunctions.net") == true)
        #expect(req.url?.absoluteString.contains("nine-events") == true)
        #expect(req.value(forHTTPHeaderField: "Referer") == "https://thegreenroom42.venuetix.com/")
        #expect(req.value(forHTTPHeaderField: "Origin") == "https://thegreenroom42.venuetix.com")
    }

    @Test func fetchReadsUpcomingShowsAttributedToTheVenue() async throws {
        let url = URL(string: "https://thegreenroom42.venuetix.com/")!
        let before = Date(timeIntervalSince1970: 1_781_000_000)   // before the fixture's show dates
        let result = try await VenueTixCalendar.fetch(url: url, venueName: "The Green Room 42", now: before) { _ in
            Data(Self.feed.utf8)
        }
        #expect(result.normalizedHTML.contains("Luigi: The Musical"))
        #expect(result.normalizedHTML.contains("The Green Room 42"))
        #expect(result.finalURL == url.absoluteString)
        #expect(!result.contentHash.isEmpty)
    }

    // A feed fetch that fails must throw, never return an empty document: an empty list would read to the
    // reconcile as "every show was cancelled".
    @Test func fetchThrowsWhenTheFeedFails() async throws {
        struct FeedError: Error {}
        let url = URL(string: "https://thegreenroom42.venuetix.com/")!
        await #expect(throws: FeedError.self) {
            _ = try await VenueTixCalendar.fetch(url: url, venueName: "The Green Room 42", now: Date()) { _ in
                throw FeedError()
            }
        }
    }

    @Test func sourceFetcherRoutesVenuetixUrlsAndThreadsTheVenueName() async throws {
        let vt = URL(string: "https://thegreenroom42.venuetix.com/")!
        let stub = FetchedPage(normalizedHTML: "VT-STUB", finalURL: vt.absoluteString, contentHash: "h")
        var threadedName: String?
        let out = try await SourceFetcher.fetch(vt, sourceName: "The Green Room 42",
                                                venuetixFeed: { _, name, _ in threadedName = name; return stub })
        #expect(out.normalizedHTML == "VT-STUB")
        #expect(threadedName == "The Green Room 42")   // the source's orgName reaches the adapter
    }

    // #1175: the feed carries only an opaque venue id, no city, so a single-venue source resolves to
    // `.unknown` in the geography gate rather than the confirmed NYC it is. When Dan supplies the venue's
    // location, it is stamped into every event's place line so the extractor reads a real city and the gate
    // places the shows in-region. The address string itself is one Dan wrote, not the app's own voice.
    @Test func synthesizesTheVenueLocationWhenProvided() throws {
        let events = try VenueTixCalendar.parseEvents(Data(Self.feed.utf8))
        let html = VenueTixCalendar.listingHTML(events, venueName: "The Green Room 42",
                                                location: "570 Tenth Ave, New York, NY 10036")
        #expect(html.contains("570 Tenth Ave, New York, NY 10036"))
        // The location EventPlace reads out of that string must place in-range, closing the actual gap.
        #expect(EventPlace.resolve(location: "570 Tenth Ave, New York, NY 10036",
                                   discipline: .music).verdict == .inRange)
    }

    // With no location supplied the document is unchanged, so an existing source with no location behaves
    // exactly as before (no churn to its content hash from this feature).
    @Test func omitsTheLocationLineWhenNoneProvided() throws {
        let events = try VenueTixCalendar.parseEvents(Data(Self.feed.utf8))
        let withNil = VenueTixCalendar.listingHTML(events, venueName: "The Green Room 42", location: nil)
        let legacy = VenueTixCalendar.listingHTML(events, venueName: "The Green Room 42")
        #expect(withNil == legacy)
    }

    @Test func fetchThreadsTheVenueLocationIntoTheDocument() async throws {
        let url = URL(string: "https://thegreenroom42.venuetix.com/")!
        let before = Date(timeIntervalSince1970: 1_781_000_000)
        let result = try await VenueTixCalendar.fetch(url: url, venueName: "The Green Room 42",
                                                      location: "New York, NY", now: before) { _ in
            Data(Self.feed.utf8)
        }
        #expect(result.normalizedHTML.contains("New York, NY"))
    }

    // #1174: the feed tags every night of one production with a shared seriesId (Green Room 42 routinely
    // runs a show on multiple nights). The parse now carries that id through, so the pieces that surface a
    // multi-night run to Dan can key on the feed's own production id rather than on date proximity. A
    // tolerant decode means a numeric or null id never fails the whole parse; here the two fixture shows
    // are genuinely different productions.
    @Test func parseCarriesTheSeriesId() throws {
        let events = try VenueTixCalendar.parseEvents(Data(Self.feed.utf8))
        #expect(events[0].seriesId == "s1")
        #expect(events[1].seriesId == "s2")
    }

    // A feed that names no production id (and one whose id is null) parses fine and simply carries no id,
    // so the absence of the id is never read as "these are the same show".
    @Test func aMissingOrNullSeriesIdParsesAsNoId() throws {
        let feed = #"""
        [
          {"title":"Show One","dateTime":1781832600000,"venue":"v"},
          {"title":"Show Two","seriesId":null,"dateTime":1781919000000,"venue":"v"}
        ]
        """#
        let events = try VenueTixCalendar.parseEvents(Data(feed.utf8))
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.seriesId == nil })
    }

    @Test func sourceFetcherThreadsTheSourceLocationToTheAdapter() async throws {
        let vt = URL(string: "https://thegreenroom42.venuetix.com/")!
        let stub = FetchedPage(normalizedHTML: "VT-STUB", finalURL: vt.absoluteString, contentHash: "h")
        var threadedLocation: String? = "unset"
        _ = try await SourceFetcher.fetch(vt, sourceName: "The Green Room 42",
                                          sourceLocation: "New York, NY",
                                          venuetixFeed: { _, _, location in threadedLocation = location; return stub })
        #expect(threadedLocation == "New York, NY")
    }
}
