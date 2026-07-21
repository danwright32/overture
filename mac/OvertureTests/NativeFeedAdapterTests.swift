import Testing
import Foundation
import SwiftData
@testable import Overture

// #1237: the two host-routed feed adapters (OPERA America, VenueTix) already parse their venues' shows
// into clean structured events, then throw that away by synthesizing HTML for a PAID AI read. These make
// them ingest natively for FREE, the way Carnegie's Algolia feed already does: a new SourceKind whose
// usesNativeExtractor is true, a SourceExtractor conformer per adapter that maps the already-parsed events
// straight to ExtractedEvent, and a per-source registry so runNative picks the right extractor per source
// instead of always Carnegie. TicketTailor is deliberately NOT here: it returns raw HTML (no structured
// parse) and is discovered mid-fetch on arbitrary hosts, not host-routed, so it stays on the paid path.
@Suite("Native feed adapters (#1237)")
struct NativeFeedAdapterTests {

    // MARK: SourceKind routing and the native-dispatch rule

    @Test func theTwoFeedHostsRouteToNativeKindsAndEverythingElseToHtml() {
        #expect(SourceKind.forListingURL(URL(string: "https://www.operaamerica.org/calendar")) == .operaAmericaFeed)
        #expect(SourceKind.forListingURL(URL(string: "https://thegreenroom42.venuetix.com/")) == .venueTixFeed)
        #expect(SourceKind.forListingURL(URL(string: "https://some-org.example/events")) == .html)
        #expect(SourceKind.forListingURL(nil) == .html)
    }

    @Test func theNativeFeedKindsIngestForFreeLikeAlgolia() {
        #expect(SourceKind.operaAmericaFeed.usesNativeExtractor)
        #expect(SourceKind.venueTixFeed.usesNativeExtractor)
        #expect(SourceKind.algolia.usesNativeExtractor)
        #expect(SourceKind.html.usesNativeExtractor == false)
    }

    // MARK: OPERA America event mapping

    @Test func operaEventsMapEveryFieldTheAiPathWouldHaveRead() {
        let events = try! OperaAmericaCalendar.parsePage(Data(OperaAmericaCalendarTests.feedPage1.utf8)).events
        let mapped = OperaAmericaCalendar.extractedEvents(from: events)

        #expect(mapped.count == 2)
        let first = mapped[0]
        #expect(first.title == "Fellow Travelers")
        // The producing opera COMPANY is the presenter to pitch, not the venue (which the feed even omits here).
        #expect(first.presenter == "Glimmerglass Festival")
        #expect(first.venue == nil)                                  // the feed really omits venue for this item
        #expect(first.location == "Cooperstown, NY")                 // #970: where the page says it is, verbatim
        #expect(first.performanceDate == "2026-07-18")               // explicit ISO day, never implied
        #expect(first.sourceUrl == "http://www.glimmerglass.org")
        #expect(first.seriesId == nil)                               // OPERA publishes no production id

        #expect(mapped[1].venue == "Norton Hall")
        #expect(mapped[1].presenter == "Chautauqua Opera")
    }

    @Test func operaEventWithNoCityOrStateHasNoLocationRatherThanAnEmptyString() {
        let bare = OperaAmericaCalendar.OAEvent(title: "Untitled", company: "", date: Date(timeIntervalSince1970: 0),
                                                time: nil, venue: nil, city: nil, state: nil, eventLink: nil)
        let mapped = OperaAmericaCalendar.extractedEvents(from: [bare])
        #expect(mapped[0].location == nil)
        #expect(mapped[0].presenter == nil)                          // an empty company is nil, not ""
    }

    // MARK: VenueTix event mapping

    @Test func venueTixEventsAreAttributedToTheVenueAndCarryDansLocation() {
        let events = try! VenueTixCalendar.parseEvents(Data(VenueTixCalendarTests.feed.utf8))
        let mapped = VenueTixCalendar.extractedEvents(from: events, venueName: "The Green Room 42",
                                                      location: "570 Tenth Ave, New York, NY")
        #expect(mapped.count == 2)
        let first = mapped[0]
        #expect(first.title == "Luigi: The Musical")
        #expect(first.venue == "The Green Room 42")
        #expect(first.location == "570 Tenth Ave, New York, NY")
        // The marketing super/sub titles are not org or place data, so they do not pollute the pitchable identity.
        #expect(first.title.contains("hashbrowns") == false)
        #expect(first.title.contains("sell out") == false)
    }

    // #1174: only a production that runs MORE THAN ONE night in this feed gets a shared seriesId, so those
    // nights collapse into one run downstream; a single-night show keeps a nil id so it still merges by the
    // gap-and-title walk if a sibling appears. This mirrors exactly what the HTML `seriesTags` path produced.
    @Test func onlyMultiNightRunsCarryASharedSeriesId() {
        func ev(_ title: String, _ series: String?, _ day: TimeInterval) -> VenueTixCalendar.VTEvent {
            VenueTixCalendar.VTEvent(title: title, superTitle: nil, subTitle: nil,
                                     date: Date(timeIntervalSince1970: day), seriesId: series)
        }
        let events = [ev("Run A night 1", "s1", 2_000_000_000),
                      ev("Run A night 2", "s1", 2_000_086_400),
                      ev("One-off", "s2", 2_000_200_000)]
        let mapped = VenueTixCalendar.extractedEvents(from: events, venueName: "V", location: nil)
        #expect(mapped[0].seriesId == "s1")
        #expect(mapped[1].seriesId == "s1")
        #expect(mapped[2].seriesId == nil)                           // single night: no id, so it never wrongly collapses
    }

    // MARK: The per-source extractor registry

    @Test func theRegistryPicksEachNativeFeedsOwnExtractorAndFallsThroughForCarnegieAndHtml() {
        let opera = WatchedSource(sourceId: "operaamerica.org", orgName: "OPERA America",
                                  listingsURL: "https://www.operaamerica.org/calendar", kind: .operaAmericaFeed)
        let venue = WatchedSource(sourceId: "greenroom", orgName: "The Green Room 42",
                                  listingsURL: "https://thegreenroom42.venuetix.com/", kind: .venueTixFeed)
        let html = WatchedSource(sourceId: "org", orgName: "Org",
                                 listingsURL: "https://org.example/e", kind: .html)

        #expect(SourceExtractorRegistry.extractor(for: opera) is OperaAmericaExtractor)
        #expect(SourceExtractorRegistry.extractor(for: venue) is VenueTixExtractor)
        // Carnegie (nil source) and a plain html source both fall through to the injected fallback extractor.
        #expect(SourceExtractorRegistry.extractor(for: nil) == nil)
        #expect(SourceExtractorRegistry.extractor(for: html) == nil)
    }

    // MARK: The extractor conformers derive the verdict like any structured feed

    @Test func operaExtractorReportsUpcomingListingsFromParsedEvents() async throws {
        let extractor = OperaAmericaExtractor(fetchEvents: {
            [OperaAmericaCalendar.OAEvent(title: "A Show", company: "Some Opera",
                                          date: Date(timeIntervalSince1970: 2_000_000_000),
                                          time: nil, venue: "A Hall", city: "Albany", state: "NY", eventLink: nil)]
        })
        let listing = try await extractor.extract()
        #expect(listing.verdict == .upcomingListings)
        #expect(listing.events.first?.presenter == "Some Opera")
    }

    // Reconcile safety: a fetch failure THROWS (it must never hand back an empty list, which the reconcile
    // would read as "every show was cancelled" and strike real shows). The empty-vs-broken distinction is
    // exactly what the feed adapters already guard, and the native path must not lose it.
    @Test func venueTixExtractorThrowsOnFailureRatherThanReturningAnEmptyList() async {
        struct Boom: Error {}
        let extractor = VenueTixExtractor(fetchEvents: { throw Boom() }, venueName: "V", location: nil)
        await #expect(throws: Boom.self) { _ = try await extractor.extract() }
    }

    @Test func venueTixExtractorWithGenuinelyNoShowsReportsNoDatedContent() async throws {
        let extractor = VenueTixExtractor(fetchEvents: { [] }, venueName: "V", location: nil)
        let listing = try await extractor.extract()
        #expect(listing.events.isEmpty)
        #expect(listing.verdict == .noDatedContent)
    }

    // MARK: The launch migration flips an existing watched feed row onto the native path

    @MainActor
    @Test func backfillMigratesExistingHtmlFeedRowsToTheirNativeKind() throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let opera = WatchedSource(sourceId: "operaamerica.org", orgName: "OPERA America",
                                  listingsURL: "https://www.operaamerica.org/calendar", kind: .html)
        let venue = WatchedSource(sourceId: "greenroom", orgName: "The Green Room 42",
                                  listingsURL: "https://thegreenroom42.venuetix.com/", kind: .html)
        let plain = WatchedSource(sourceId: "org", orgName: "Org",
                                  listingsURL: "https://org.example/events", kind: .html)
        ctx.insert(opera); ctx.insert(venue); ctx.insert(plain)

        WatchedSourceBackfill.run(in: ctx, defaults: UserDefaults(suiteName: "nfa-\(UUID())")!)

        #expect(opera.kind == .operaAmericaFeed)
        #expect(venue.kind == .venueTixFeed)
        #expect(plain.kind == .html)                                 // an ordinary source is untouched
    }

    // MARK: The scout actually consults the registry per source

    // The behavioral guard on the dispatch itself: a native feed row is read through the extractor the
    // registry hands it, NOT the injected fallback (Carnegie, in production). If the loop ever stops
    // consulting the registry, the fallback runs, surfaces nothing, and this fails.
    @MainActor
    @Test func runScoutReadsANativeFeedSourceThroughTheRegistryNotTheFallback() async throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let venue = WatchedSource(sourceId: "greenroom", orgName: "The Green Room 42",
                                  listingsURL: "https://thegreenroom42.venuetix.com/", kind: .venueTixFeed)
        ctx.insert(venue)

        // The registry hands THIS source a stub that surfaces one show; the fallback surfaces nothing.
        let viaRegistry = StubSourceExtractor(listing: ExtractedListing(
            events: [ExtractedEvent(title: "Luigi: The Musical", presenter: "The Green Room 42",
                                    venue: "The Green Room 42", performanceDate: "2026-12-31",
                                    sourceUrl: nil, location: "New York, NY")],
            verdict: .upcomingListings))
        let fallback = StubSourceExtractor(listing: ExtractedListing(events: [], verdict: .upcomingListings))

        _ = try await ScoutService.runScout(
            into: ctx, extractor: fallback,
            extractorRegistry: { $0?.sourceId == "greenroom" ? viaRegistry : nil },
            fetch: { url, _, _ in FetchedPage(normalizedHTML: "", finalURL: url.absoluteString, contentHash: "h") },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            defaults: UserDefaults(suiteName: "nfa-dispatch-\(UUID().uuidString)")!)

        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(stored.contains { $0.groupName.contains("Luigi") })
        #expect(viaRegistry.callCount == 1)
        #expect(fallback.callCount == 0)                             // the fallback was never reached
    }
}
