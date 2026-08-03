import Testing
import Foundation
import SwiftData

// #1280 Phase 4 (#1296): the whole feature end to end. Real TicketTailor widget bytes (the same shape the
// live all-tickets-calendar embeds) go through the scout read path all the way to a STORED prospect, for
// free, with no paid read launched.
//
// The date must be in the future of the app's REAL Eastern 'today': the native ingest's upcoming-only
// guard (#798, applySweep) uses the real day, not the scout's injected now (#1302), so a past-dated
// fixture would be (correctly) dropped as already gone. It is computed RELATIVE to today, not hardcoded,
// so this test can never silently expire once the real date passes a fixed one. The location is an
// in-borough NYC one so the geography gate places the MUSIC show in range (music "stays in the boroughs",
// #970).
@MainActor
@Suite("TicketTailor end to end to a prospect (#1296)")
struct TicketTailorEndToEndTests {
    // A yyyy-MM-dd well into the future, in the same zone the parser reads keys with, so it round-trips to
    // the same string on the prospect and stays ahead of both the real clock and easternToday.
    private static func futureDateString(daysFromNow days: Int = 120) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date().addingTimeInterval(TimeInterval(days) * 86_400))
    }

    private static func widget(date: String) -> String {
        #"""
        <html><body><script>var selectableDates = {"\#(date)":{"available":true,"sold_out":false,"event_series":[{"series_id":701,"name":"Autumn Chamber Concert","venue":"The Cell Theatre","event_page_url":"/events/thecell/701"}]}};</script></body></html>
        """#
    }

    private final class LaunchBox { var launched = false }

    @Test func aTicketTailorWidgetIngestsAllTheWayToAStoredProspectForFree() async throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let source = WatchedSource(sourceId: "cell", orgName: "The Cell Theatre",
                                   listingsURL: "https://thecelltheatre.org/box-office", kind: .html)
        source.venueLocation = "New York, NY"   // Manhattan: in-borough for the geography gate
        ctx.insert(source)
        let box = LaunchBox()
        let date = Self.futureDateString()

        _ = try await ScoutService.runScout(
            into: ctx,
            fetch: { url, _, _ in
                FetchedPage(normalizedHTML: "<html><body>widget shell</body></html>",
                            finalURL: url.absoluteString, contentHash: "e2e-hash-1",
                            ticketTailorWidgetHTML: Self.widget(date: date))
            },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
            launch: { _ in box.launched = true },
            defaults: UserDefaults(suiteName: "tt-e2e-\(UUID().uuidString)")!)

        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        let p = try #require(stored.first { $0.groupName == "Autumn Chamber Concert" },
                             "stored=\(stored.map(\.groupName))")
        #expect(box.launched == false)                  // ingested natively, no paid read
        #expect(p.venue == "The Cell Theatre")          // the feed's own venue field
        #expect(p.performanceDate == date)
        #expect(p.sourceListingURL == "https://www.tickettailor.com/events/thecell/701")
        #expect(source.lastContentHash == "e2e-hash-1") // marked ingested; next unchanged run skips it
    }

    // #1302: the native ingest's upcoming-only guard (applySweep) must honor the scout's INJECTED now, not
    // the real wall clock. A show dated in the future of the injected now but the PAST of the real clock
    // must still ingest. Before the fix applySweep read the real 'today' (runNative never threaded its now
    // through), so it silently dropped the show (found>0, inserted=0), indistinguishable from a
    // geography/classifier rejection and forcing every native e2e test to be real-clock-dependent. All dates
    // are relative to Date(), so this can never expire.
    @Test func aScoutWithAnInjectedNowIngestsAShowUpcomingRelativeToThatNow() async throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let source = WatchedSource(sourceId: "cell", orgName: "The Cell Theatre",
                                   listingsURL: "https://thecelltheatre.org/box-office", kind: .html)
        source.venueLocation = "New York, NY"   // Manhattan: in-borough for the geography gate
        ctx.insert(source)

        // A 'now' well over a year in the past, and a show ~200 days after it: comfortably UPCOMING for the
        // injected now, comfortably PAST for the real clock, so a real-today guard would (wrongly) drop it.
        let injectedNow = Date().addingTimeInterval(-400 * 86_400)
        let date = Self.futureDateString(daysFromNow: -200)

        _ = try await ScoutService.runScout(
            into: ctx,
            fetch: { url, _, _ in
                FetchedPage(normalizedHTML: "<html><body>widget shell</body></html>",
                            finalURL: url.absoluteString, contentHash: "e2e-hash-1302",
                            ticketTailorWidgetHTML: Self.widget(date: date))
            },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
            launch: { _ in },
            now: injectedNow,
            defaults: UserDefaults(suiteName: "tt-e2e-1302-\(UUID().uuidString)")!)

        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        let p = try #require(stored.first { $0.groupName == "Autumn Chamber Concert" },
                             "a show upcoming for the injected now was dropped; stored=\(stored.map(\.groupName))")
        #expect(p.performanceDate == date)
    }
}
