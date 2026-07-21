import Testing
import Foundation
import SwiftData
@testable import Overture

// #1280 Phase 4 (#1296): the whole feature end to end. Real TicketTailor widget bytes (the same shape the
// live all-tickets-calendar embeds) go through the scout read path all the way to a STORED prospect, for
// free, with no paid read launched.
//
// The date is deliberately in the future of the app's REAL Eastern 'today': the native ingest's
// upcoming-only guard (#798, applySweep) uses the real day, not the scout's injected now, so a past-dated
// fixture would be (correctly) dropped as already gone. The location is an in-borough NYC one so the
// geography gate places the MUSIC show in range (music "stays in the boroughs", #970).
@MainActor
@Suite("TicketTailor end to end to a prospect (#1296)")
struct TicketTailorEndToEndTests {
    private static let widget = #"""
    <html><body><script>var selectableDates = {"2026-09-15":{"available":true,"sold_out":false,"formatted_date":"Tue 15 Sep 2026","event_series":[{"series_id":701,"name":"Autumn Chamber Concert","venue":"The Cell Theatre","event_page_url":"/events/thecell/701"}]}};</script></body></html>
    """#

    private final class LaunchBox { var launched = false }

    @Test func aTicketTailorWidgetIngestsAllTheWayToAStoredProspectForFree() async throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let source = WatchedSource(sourceId: "cell", orgName: "The Cell Theatre",
                                   listingsURL: "https://thecelltheatre.org/box-office", kind: .html)
        source.venueLocation = "New York, NY"   // Manhattan: in-borough for the geography gate
        ctx.insert(source)
        let box = LaunchBox()

        _ = try await ScoutService.runScout(
            into: ctx,
            fetch: { url, _, _ in
                FetchedPage(normalizedHTML: "<html><body>widget shell</body></html>",
                            finalURL: url.absoluteString, contentHash: "e2e-hash-1",
                            ticketTailorWidgetHTML: Self.widget)
            },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
            launch: { _ in box.launched = true },
            defaults: UserDefaults(suiteName: "tt-e2e-\(UUID().uuidString)")!)

        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        let p = try #require(stored.first { $0.groupName == "Autumn Chamber Concert" },
                             "stored=\(stored.map(\.groupName))")
        #expect(box.launched == false)                  // ingested natively, no paid read
        #expect(p.venue == "The Cell Theatre")          // the feed's own venue field
        #expect(p.performanceDate == "2026-09-15")
        #expect(p.sourceListingURL == "https://www.tickettailor.com/events/thecell/701")
        #expect(source.lastContentHash == "e2e-hash-1") // marked ingested; next unchanged run skips it
    }
}
