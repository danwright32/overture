import Testing
import Foundation

// #1280 Phase 2 (#1294): the SourceExtractor conformer that wraps the TicketTailorCalendar parser. Like
// VenueTixExtractor, the event fetch is injected so the whole extractor is a real unit test with no
// network. The load-bearing new behavior vs the single-URL feeds is the TWO-HOP failure: the venue page
// can load (200) yet carry no widget embed, which MUST throw (not return []), or reconcile would read the
// now-empty feed as every stored show cancelled (#887/#897).
@Suite("TicketTailor extractor (#1280)")
struct TicketTailorExtractorTests {
    private let venueURL = URL(string: "https://www.thecelltheatre.org/box-office")!
    // Before the fixture's dates (2026-07-21/22) so the upcoming filter keeps both regardless of the clock.
    private let now = Date(timeIntervalSince1970: 1_782_000_000)

    // A `get` that answers the venue page with (optionally) a TicketTailor embed, and the widget URL with
    // the real populated widget bytes. The widget hop is recognized by its all-tickets-calendar URL.
    private func twoHopGet(pageCarriesEmbed: Bool) -> @Sendable (URLRequest) async throws -> Data {
        { req in
            let u = req.url?.absoluteString ?? ""
            if u.contains("all-tickets-calendar") {
                return Data(TicketTailorCalendarTests.populated.utf8)
            }
            let page = pageCarriesEmbed
                ? #"<html><body><div class="tt-widget" data-url="https://www.tickettailor.com/all-tickets-calendar/thecelltheatre/"></div></body></html>"#
                : "<html><body>the venue redesigned and the box office embed is gone</body></html>"
            return Data(page.utf8)
        }
    }

    @Test func extractMapsInjectedEventsToAListing() async throws {
        let extractor = TicketTailorExtractor(
            fetchEvents: {
                try TicketTailorCalendar.parseWidget(TicketTailorCalendarTests.populated)
            },
            venueName: "The Cell", location: "New York, NY")

        let listing = try await extractor.extract()

        #expect(listing.verdict == .upcomingListings)
        #expect(listing.events.count == 3)
        let beach = try #require(listing.events.first { $0.title == "Beach visits" })
        #expect(beach.venue == "Sparkling Waters, Golden sands")   // feed field
        #expect(beach.location == "New York, NY")
    }

    @Test func anEmptyWidgetYieldsAQuietNoDatedContentVerdict() async throws {
        let extractor = TicketTailorExtractor(fetchEvents: { [] }, venueName: "The Cell", location: nil)
        let listing = try await extractor.extract()
        #expect(listing.events.isEmpty)
        #expect(listing.verdict == .noDatedContent)   // a quiet empty calendar, NOT a failure
    }

    @Test func theLiveTwoHopReadsTheVenuePageThenTheWidget() async throws {
        let get = twoHopGet(pageCarriesEmbed: true)
        let url = venueURL, when = now
        let extractor = TicketTailorExtractor(
            fetchEvents: { try await TicketTailorCalendar.liveEvents(pageURL: url, now: when, get: get) },
            venueName: "The Cell", location: "New York, NY")
        let listing = try await extractor.extract()
        #expect(listing.verdict == .upcomingListings)
        #expect(Set(listing.events.map(\.title)) == ["Beach visits", "Sunset Jazz"])
    }

    // Cancellation safety: a 200 venue page with the embed GONE must throw, never return an empty listing
    // that reconcile would read as every stored show cancelled.
    @Test func aVenuePageThatNoLongerCarriesTheEmbedThrowsRatherThanReportingEmpty() async throws {
        let get = twoHopGet(pageCarriesEmbed: false)
        let url = venueURL, when = now
        let extractor = TicketTailorExtractor(
            fetchEvents: { try await TicketTailorCalendar.liveEvents(pageURL: url, now: when, get: get) },
            venueName: "The Cell", location: nil)
        await #expect(throws: SourceFetchError.feedShapeChanged) {
            _ = try await extractor.extract()
        }
    }
}
