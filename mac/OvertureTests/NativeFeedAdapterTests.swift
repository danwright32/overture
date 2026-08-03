import Testing
import Foundation
import SwiftData

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
        #expect(SourceKind.forListingURL(URL(string: "https://ci.ovationtix.com/35583")) == .ovationTixFeed)  // #1344
        #expect(SourceKind.forListingURL(URL(string: "https://some-org.example/events")) == .html)
        #expect(SourceKind.forListingURL(nil) == .html)
    }

    @Test func theNativeFeedKindsIngestForFreeLikeAlgolia() {
        #expect(SourceKind.operaAmericaFeed.usesNativeExtractor)
        #expect(SourceKind.venueTixFeed.usesNativeExtractor)
        #expect(SourceKind.ovationTixFeed.usesNativeExtractor)                                              // #1344
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
        let mapped = VenueTixCalendar.extractedEvents(from: events, presenter: "The Green Room 42",
                                                      venue: "The Green Room 42",
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

    // #1680: the feed publishes an eventId and a seriesId for every row, and the venue's own site navigates
    // its cards to /showdetails/{seriesId}/{eventId} (confirmed against the live site's router, 2026-07-28).
    // The adapter threw both away and set sourceUrl nil, which is why all 129 untriaged Green Room 42 rows
    // on the live store have no link back to the page they came from.
    @Test func venueTixEventsCarryALinkToTheirOwnPage() {
        let events = try! VenueTixCalendar.parseEvents(Data(VenueTixCalendarTests.feed.utf8))
        let source = URL(string: "https://thegreenroom42.venuetix.com/")!
        let mapped = VenueTixCalendar.extractedEvents(from: events, presenter: "The Green Room 42",
                                                      venue: "The Green Room 42", location: nil,
                                                      sourceURL: source)
        #expect(mapped[0].sourceUrl == "https://thegreenroom42.venuetix.com/showdetails/s1/a1")
        #expect(mapped[1].sourceUrl == "https://thegreenroom42.venuetix.com/showdetails/s2/a2")
    }

    // Dan's call (2026-07-28): a row that cannot produce a per-event link falls back to the source's own
    // calendar rather than showing nothing, because "no link" and "no link to THIS show" are different
    // facts and only one of them leaves him with nowhere to click. The card labels the two differently.
    @Test func aVenueTixRowWithNoIdsFallsBackToTheVenuesCalendar() {
        let bare = VenueTixCalendar.VTEvent(title: "Unidentified", superTitle: nil, subTitle: nil,
                                            date: Date(timeIntervalSince1970: 2_000_000_000), seriesId: nil)
        let source = URL(string: "https://thegreenroom42.venuetix.com/")!
        let mapped = VenueTixCalendar.extractedEvents(from: [bare], presenter: "V", venue: "V",
                                                      location: nil, sourceURL: source)
        #expect(mapped[0].sourceUrl == "https://thegreenroom42.venuetix.com/")
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
        let mapped = VenueTixCalendar.extractedEvents(from: events, presenter: "V", venue: "V", location: nil)
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
        let ovation = WatchedSource(sourceId: "sohoplayhouse", orgName: "SoHo Playhouse",
                                    listingsURL: "https://ci.ovationtix.com/35583", kind: .ovationTixFeed)
        let html = WatchedSource(sourceId: "org", orgName: "Org",
                                 listingsURL: "https://org.example/e", kind: .html)

        #expect(SourceExtractorRegistry.extractor(for: opera) is OperaAmericaExtractor)
        #expect(SourceExtractorRegistry.extractor(for: venue) is VenueTixExtractor)
        #expect(SourceExtractorRegistry.extractor(for: ovation) is OvationTixExtractor)   // #1344
        // Carnegie (nil source) and a plain html source both fall through to the injected fallback extractor.
        #expect(SourceExtractorRegistry.extractor(for: nil) == nil)
        #expect(SourceExtractorRegistry.extractor(for: html) == nil)
    }

    // #1680: SoHo Playhouse's 16 linkless rows. The feed names the production and, under each date, that
    // date's own performanceId, so one night of a run is addressable. The shape is the one already observed
    // in Dan's store for another OvationTix venue, written there by the AI path, so it is copied rather
    // than invented.
    @Test func ovationTixEventsCarryALinkToTheirOwnNight() {
        let events = try! OvationTixCalendar.parseEvents(Data(OvationTixCalendarTests.feed.utf8))
        let source = URL(string: "https://ci.ovationtix.com/35583")!
        let mapped = OvationTixCalendar.extractedEvents(from: events, presenter: "SoHo Playhouse",
                                                        venue: "SoHo Playhouse", location: nil,
                                                        sourceURL: source)
        let hungryFirstNight = mapped.first { $0.title == "Hungry Women" }
        #expect(hungryFirstNight?.sourceUrl
                == "https://ci.ovationtix.com/35583/production/1280419?performanceId=11817828")
        // The SECOND night of the same run points at its own night, not the first one's.
        let hungryNights = mapped.filter { $0.title == "Hungry Women" }.compactMap(\.sourceUrl)
        #expect(Set(hungryNights).count == hungryNights.count)
    }

    @Test func anOvationTixRowWithNoProductionIdFallsBackToTheVenuesCalendar() {
        let bare = OvationTixCalendar.OTEvent(title: "Unidentified", superTitle: nil, subTitle: nil,
                                              date: Date(timeIntervalSince1970: 2_000_000_000), seriesId: nil)
        let source = URL(string: "https://ci.ovationtix.com/35583")!
        let mapped = OvationTixCalendar.extractedEvents(from: [bare], presenter: "V", venue: "V",
                                                        location: nil, sourceURL: source)
        #expect(mapped[0].sourceUrl == "https://ci.ovationtix.com/35583")
    }

    @Test func theRegistryHandsTheOvationTixExtractorTheSourcesOwnAddress() {
        let ovation = WatchedSource(sourceId: "sohoplayhouse", orgName: "SoHo Playhouse",
                                    listingsURL: "https://ci.ovationtix.com/35583", kind: .ovationTixFeed)
        let extractor = SourceExtractorRegistry.extractor(for: ovation) as? OvationTixExtractor
        #expect(extractor?.sourceURL?.absoluteString == "https://ci.ovationtix.com/35583")
    }

    // #1680: the registry builds the VenueTix extractor through its MEMBERWISE init, not the convenience one
    // that takes a url, so threading the source URL into the extractor is not enough on its own: the live
    // path runs through here. Without this the adapter's own tests stay green while every real Green Room 42
    // card is still linkless, which is exactly how this defect survived (L3, built is not wired).
    @Test func theRegistryHandsTheVenueTixExtractorTheSourcesOwnAddress() {
        let venue = WatchedSource(sourceId: "greenroom", orgName: "The Green Room 42",
                                  listingsURL: "https://thegreenroom42.venuetix.com/", kind: .venueTixFeed)
        let extractor = SourceExtractorRegistry.extractor(for: venue) as? VenueTixExtractor
        #expect(extractor?.sourceURL?.absoluteString == "https://thegreenroom42.venuetix.com/")
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
        let extractor = VenueTixExtractor(fetchEvents: { throw Boom() }, presenter: "V", venue: "V", location: nil)
        await #expect(throws: Boom.self) { _ = try await extractor.extract() }
    }

    @Test func venueTixExtractorWithGenuinelyNoShowsReportsNoDatedContent() async throws {
        let extractor = VenueTixExtractor(fetchEvents: { [] }, presenter: "V", venue: "V", location: nil)
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
        // #1344: the real SoHo Playhouse row, watched as .html before this adapter existed, flips for free.
        let ovation = WatchedSource(sourceId: "sohoplayhouse", orgName: "SoHo Playhouse",
                                    listingsURL: "https://ci.ovationtix.com/35583", kind: .html)
        let plain = WatchedSource(sourceId: "org", orgName: "Org",
                                  listingsURL: "https://org.example/events", kind: .html)
        ctx.insert(opera); ctx.insert(venue); ctx.insert(ovation); ctx.insert(plain)

        WatchedSourceBackfill.run(in: ctx, defaults: UserDefaults(suiteName: "nfa-\(UUID())")!)

        #expect(opera.kind == .operaAmericaFeed)
        #expect(venue.kind == .venueTixFeed)
        #expect(ovation.kind == .ovationTixFeed)                     // #1344: SoHo Playhouse auto-flipped
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
