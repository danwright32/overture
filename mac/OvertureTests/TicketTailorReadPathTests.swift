import Testing
import Foundation
import SwiftData

// #1280 Phase 3 (#1295): when the scout READS an .html source whose fetched page is a TicketTailor widget
// (FetchedPage.ticketTailorWidgetHTML set by the fetch hop), it parses the embedded selectableDates JSON
// NATIVELY (free) instead of handing the widget HTML to the paid detached read. These pin the wiring: the
// show ingests, no paid read is launched, the source is marked ingested once (not double-counted), and an
// empty widget is a quiet no-op rather than a failure.
@MainActor
@Suite("TicketTailor native read path (#1295)")
struct TicketTailorReadPathTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }
    // Before the widget's date (2026-07-15) and within the horizon, so the show survives the upcoming and
    // four-month filters regardless of the wall clock.
    private let now = Date(timeIntervalSince1970: 1_782_000_000)

    private final class LaunchBox { var launched = false }

    private func ticketTailorSource(in ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: "cell", orgName: "The Cell Theatre",
                              listingsURL: "https://thecelltheatre.org/box-office", kind: .html)
        s.venueLocation = "New York, NY"   // so the geography gate places the shows in-region
        ctx.insert(s)
        return s
    }

    private func page(widgetHTML: String, hash: String) -> FetchedPage {
        FetchedPage(normalizedHTML: "<html><body>widget shell</body></html>",
                    finalURL: "https://thecelltheatre.org/box-office", contentHash: hash,
                    ticketTailorWidgetHTML: widgetHTML)
    }

    private static let populatedWidget = #"""
    <script>var selectableDates = {"2026-07-15":{"available":true,"formatted_date":"Wed 15 Jul 2026","event_series":[{"series_id":88,"name":"Chamber Music Recital","venue":"Weill Recital Hall","event_page_url":"/events/thecell/88"}]}};</script>
    """#

    @Test func aChangedTicketTailorWidgetIsParsedNativelyWithNoPaidRead() async throws {
        let ctx = try context()
        let source = ticketTailorSource(in: ctx)
        let box = LaunchBox()
        let p = page(widgetHTML: Self.populatedWidget, hash: "tt-hash-1")

        let outcome = try await ScoutService.runScout(
            into: ctx,
            fetch: { url, _, _ in p },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
            launch: { _ in box.launched = true },
            now: now,
            defaults: UserDefaults(suiteName: "ttrp-\(UUID().uuidString)")!)

        // The widget was parsed natively: its one show reached runNative's ingest (found), for free...
        #expect(outcome.found == 1)
        // ...and NO paid detached read was launched (whether the show then survives classify/geography to
        // become a stored prospect is the classifier's job, exercised end to end in #1296, not #1295's).
        #expect(box.launched == false)
        // The source is reported exactly once, as an ingest, not ALSO as the queued-for-reading result.
        #expect(outcome.sources.filter { $0.sourceId == "cell" }.count == 1)
        let result = try #require(outcome.sources.first { $0.sourceId == "cell" })
        #expect({ if case .ingested = result.state { return true } else { return false } }())
        // Marked ingested, so an unchanged widget is skipped next run and no detached read is ever owed.
        #expect(source.lastContentHash == "tt-hash-1")
        #expect(source.pendingContentHash == nil)
    }

    @Test func anEmptyTicketTailorWidgetIsAQuietNoOpNotAFailure() async throws {
        let ctx = try context()
        let source = ticketTailorSource(in: ctx)
        let box = LaunchBox()
        let empty = #"<script>var selectableDates = [];</script>"#

        _ = try await ScoutService.runScout(
            into: ctx,
            fetch: { url, _, _ in self.page(widgetHTML: empty, hash: "tt-empty") },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
            launch: { _ in box.launched = true },
            now: now,
            defaults: UserDefaults(suiteName: "ttrp-\(UUID().uuidString)")!)

        #expect((try ctx.fetch(FetchDescriptor<Prospect>())).isEmpty)
        #expect(box.launched == false)              // still no paid read
        #expect(source.health != .failing)          // an empty calendar is quiet, not broken
    }
}
