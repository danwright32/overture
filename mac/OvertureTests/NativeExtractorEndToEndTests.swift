import Testing
import Foundation
@testable import Overture

// #1281: native ingest's two halves are each unit-tested (real feed BYTES -> parsed events in the
// *Calendar adapters, and parsed events -> ExtractedEvent in *.extractedEvents), plus the registry
// dispatch, but nothing drove a captured real feed all the way THROUGH OperaAmericaExtractor.extract() /
// VenueTixExtractor.extract() to the mapped ExtractedListing. A feed-format drift that slips past the
// parse guards, or a regression in how the extractor wires its injected fetch to the mapping, would pass
// every existing test. This closes the join by injecting the SAME real-feed fixtures the adapter tests
// use as the extractor's network response and asserting the resulting listing.
//
// It stops at the extractor boundary (extract() -> ExtractedListing) rather than driving on to a stored
// prospect: the events -> prospect leg (the ingest guard, geography, and horizon filters) is already
// covered by NativePathGuardTests and the classifier suites, and asserting a stored row here would couple
// this join test to classifier/geography decisions that are not what it is guarding. The final test does
// assert the mapped events survive the shared ingest guard, so the join provably reaches the same
// boundary the agent path does.
@Suite("Native extractors, real feed bytes end to end (#1281)")
struct NativeExtractorEndToEndTests {
    // The fixtures' two VenueTix shows fall in mid-June 2026, so `now` is pinned before them or `upcoming`
    // would drop both.
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func venueTixExtractor() -> VenueTixExtractor {
        VenueTixExtractor(
            fetchEvents: { [now] in
                VenueTixCalendar.upcoming(
                    try VenueTixCalendar.parseEvents(Data(VenueTixCalendarTests.feed.utf8)), now: now)
            },
            presenter: "The Green Room 42", venue: "The Green Room 42", location: "New York, NY",
            sourceURL: URL(string: "https://thegreenroom42.venuetix.com/"))
    }

    // OPERA America: the real Umbraco feed page injected as the paged POST response, driven through
    // parsePage -> OAEvent -> extractedEvents -> ExtractedListing. feedPage1 reports totalPages: 30, so the
    // extractor pages on; every page after the first is an empty (well-formed, non-drift) page so
    // pagination terminates cleanly on page 1's two shows.
    @Test func operaAmericaFeedBytesReachAMappedListing() async throws {
        let page1 = Data(OperaAmericaCalendarTests.feedPage1.utf8)
        let extractor = OperaAmericaExtractor {
            try await OperaAmericaCalendar.fetchEvents(post: { page in
                page == 1
                    ? page1
                    : Data(#"{"currentPage":\#(page),"totalPages":30,"totalItems":0,"itemsPerPage":12,"items":[]}"#.utf8)
            })
        }

        let listing = try await extractor.extract()

        #expect(listing.verdict == .upcomingListings)
        #expect(listing.events.count == 2)

        let glimmerglass = listing.events[0]
        #expect(glimmerglass.title == "Fellow Travelers")
        #expect(glimmerglass.presenter == "Glimmerglass Festival")  // the producing company is the pitch target
        #expect(glimmerglass.venue == nil)                          // the feed really omits venue for this item
        #expect(glimmerglass.location == "Cooperstown, NY")         // city, state joined verbatim (#970)
        #expect(glimmerglass.performanceDate == "2026-07-18")       // explicit ISO day, never implied
        #expect(glimmerglass.sourceUrl == "http://www.glimmerglass.org")

        let chautauqua = listing.events[1]
        #expect(chautauqua.title == "Die Zauberflöte")
        #expect(chautauqua.presenter == "Chautauqua Opera")
        #expect(chautauqua.venue == "Norton Hall")
        #expect(chautauqua.location == "Chautauqua, NY")
    }

    // VenueTix: the real single-venue feed injected as the fetch response, driven through parseEvents ->
    // upcoming -> extractedEvents -> ExtractedListing, attributed to the venue name and location the source
    // row supplies (the feed itself carries only an opaque venue id).
    @Test func venueTixFeedBytesReachAMappedListing() async throws {
        let listing = try await venueTixExtractor().extract()

        #expect(listing.verdict == .upcomingListings)
        #expect(listing.events.count == 2)

        let luigi = listing.events[0]
        #expect(luigi.title == "Luigi: The Musical")
        #expect(luigi.presenter == "The Green Room 42")
        #expect(luigi.venue == "The Green Room 42")   // the opaque feed id, resolved to the threaded name
        #expect(luigi.location == "New York, NY")
        #expect(luigi.performanceDate != nil)         // exact day arithmetic is the adapter test's job, not this one's

        #expect(listing.events[1].title == "The Ethel Merman Disco Album Project")
    }

    // #1680: the capability and its WIRING are two claims. `extractedEvents` can build a per-event link, but
    // that is worth nothing unless the extractor actually hands it the source URL: without this the live path
    // keeps passing nil and every Green Room 42 card stays linkless while the adapter's own test is green.
    @Test func venueTixEventsReachTheListingCarryingTheirOwnPageLink() async throws {
        let listing = try await venueTixExtractor().extract()
        #expect(listing.events[0].sourceUrl == "https://thegreenroom42.venuetix.com/showdetails/s1/a1")
    }

    // The join reaches the SAME boundary the agent path does: every mapped event survives the ingest guard,
    // so these bytes go on to become prospects rather than being silently dropped downstream.
    @Test func mappedEventsSurviveTheIngestGuard() async throws {
        for event in try await venueTixExtractor().extract().events {
            #expect(ExtractedEventGuard.isUsable(event), "\(event.title) should survive the boundary guard")
        }
    }
}
