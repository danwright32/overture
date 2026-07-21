import Testing
import Foundation
import SwiftData
@testable import Overture

// #1210: the scout now pages forward on a site's own month links, reading the shared four-month horizon
// (CalendarMonthIndex.defaultHorizon), where it used to read only the month it landed on. This proves the
// pagination is actually turned ON for the scout, by driving the REAL paginating fetch through an injected
// stub session and asserting the source recorded that it stitched four months, not one.
//
// The reconcile-safety that makes paging forward on the reconciling watchlist path OK (a short stitched
// read downgrades to incompleteExtraction and can mark nothing gone) is proven end to end and separately in
// StitchedSweepIngestWiringTests; it is not re-proven here. This test's job is only "is it on".
@MainActor
@Suite("The scout pages forward on monthly calendars (#1210)")
struct ScoutPaginationTests {
    private let base = "https://www.kaufmanmusiccenter.org/mch/calendar/"

    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PageStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    // Enough visible text to clear the thin-text floor, so these pages are not refused as unreadable shells.
    private func monthPage(_ label: String, shows: [String]) -> String {
        let index = ["2026/07/", "2026/08/", "2026/09/", "2026/10/", "2026/11/"]
            .map { "<option value=\"\(base)\($0)\">\($0)</option>" }.joined()
        let listings = shows
            .map { "<div><a href=\"/mch/event/\($0.lowercased())\">\($0)</a> 7:30 pm</div>" }.joined()
        return """
        <html><body>
        <h1>Merkin Hall Calendar \(label)</h1>
        <select>\(index)</select>
        \(listings)
        <p>Kaufman Music Center presents concerts at Merkin Hall on the Upper West Side of Manhattan,
        with tickets, discounts, directions and rental spaces available on this site all season long.</p>
        </body></html>
        """
    }

    private func serveKaufman() {
        PageStubURLProtocol.reset()
        PageStubURLProtocol.bodiesByURL = [
            base: monthPage("July 2026", shows: ["Immortal Gifts"]),
            base + "2026/08/": monthPage("August 2026", shows: ["Summer Serenade"]),
            base + "2026/09/": monthPage("September 2026", shows: ["Autumn Opening"]),
            base + "2026/10/": monthPage("October 2026", shows: ["PUBLIQuartet"]),
            base + "2026/11/": monthPage("November 2026", shows: ["Too Far Out"]),
        ]
    }

    private func july2026() -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 13
        c.timeZone = TimeZone(identifier: "America/New_York")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    @Test func aManualScoutStitchesFourMonthsOfAPaginatedCalendar() async throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let kaufman = WatchedSource(sourceId: "kaufman", orgName: "Kaufman Music Center",
                                    listingsURL: base, kind: .html)
        kaufman.lastContentHash = "old"                  // changed since last run, so this scout reads it
        kaufman.successfulCheckCount = WatchedSource.warmupRuns
        ctx.insert(kaufman)
        serveKaufman()

        _ = try await ScoutService.runScout(
            into: ctx,
            extractor: StubSourceExtractor(listing: ExtractedListing(events: [], verdict: .upcomingListings)),
            session: stubSession(),
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            now: july2026(),
            defaults: UserDefaults(suiteName: "scout-pag-\(UUID().uuidString)")!)

        // Four months stitched from the site's own month index, not just July, the page it landed on.
        // November is past the four-month horizon and must not be read.
        #expect(kaufman.pendingPageMonths == ["2026-07", "2026-08", "2026-09", "2026-10"])
    }

    // THE FAILURE PATH, and the reason paging forward on the reconciling scout is safe. October's page
    // errors mid-stitch. The scout must record ONLY the months it actually read as the stitched set, never
    // the month it could not reach, because that set is what the completeness guard measures a later read
    // against (SweepCoverage). If a failed month were silently counted as stitched, a run that legitimately
    // read the other three could look complete and be allowed to cancel October's live shows. So the source
    // remembers three months here, and October is left out, exactly as it was left out of the document.
    @Test func aMonthThatErrorsMidStitchIsNotRecordedAsRead() async throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let kaufman = WatchedSource(sourceId: "kaufman", orgName: "Kaufman Music Center",
                                    listingsURL: base, kind: .html)
        kaufman.lastContentHash = "old"
        kaufman.successfulCheckCount = WatchedSource.warmupRuns
        ctx.insert(kaufman)
        serveKaufman()
        PageStubURLProtocol.statusByURL = [base + "2026/10/": 404]   // October cannot be read this run

        _ = try await ScoutService.runScout(
            into: ctx,
            extractor: StubSourceExtractor(listing: ExtractedListing(events: [], verdict: .upcomingListings)),
            session: stubSession(),
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            now: july2026(),
            defaults: UserDefaults(suiteName: "scout-pag-\(UUID().uuidString)")!)

        // Only the months actually read are recorded as stitched; October is not silently counted present.
        #expect(kaufman.pendingPageMonths == ["2026-07", "2026-08", "2026-09"])
        #expect(!(kaufman.pendingPageMonths).contains("2026-10"))
    }
}
