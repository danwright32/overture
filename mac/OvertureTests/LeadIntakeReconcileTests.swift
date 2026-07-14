import Testing
import Foundation
import SwiftData
@testable import Overture

// #826: confirming a hand-added lead is not a feed check. It reports on ONE page, the one Dan pasted,
// and says nothing whatever about what Carnegie is still listing. When a one-event confirm was allowed
// to run the feed reconcile, every future Carnegie prospect was absent from that "feed" and accrued a
// miss, and two confirms in a row marked Dan's live, un-cancelled shows as disappeared and hid them
// from his queue. Observed in the Debug store: a still-upcoming Carnegie show sitting at 7 misses.
//
// The last test here is the other half of the fix: the SCOUT must still reconcile. A flag that turned
// the reconcile off everywhere would pass the two tests above and quietly delete the #133 feature.
@MainActor
@Suite("A hand-added lead never reconciles the scout's feed (#826)")
struct LeadIntakeReconcileTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private static let realPageHTML =
        "<h1>Upcoming concerts</h1>"
        + "<p>Second Ending Ensemble presents an evening of chamber music at Merkin Hall, with works "
        + "by Brahms and Dvorak, followed by a conversation with the performers. Doors open at seven "
        + "and the programme begins at half past. Tickets are available at the box office or online, "
        + "and members of the ensemble stay afterwards to talk with anyone who would like to.</p>"
        + "<ul><li><a href=\"/show/1\">October 3: Piano Trios of Haydn, Brahms and Dvorak, with guests "
        + "from the orchestra, in the recital hall on the second floor</a></li></ul>"
        + "<p>All concerts begin at half past seven. The hall is fully accessible, and there is a "
        + "lift to the second floor from the lobby entrance on the street.</p>"

    private func model(_ event: ScoutExtractEvent) -> LeadIntakeModel {
        LeadIntakeModel(
            defaults: UserDefaults(suiteName: "LeadIntakeReconcileTests-\(UUID().uuidString)")!,
            fetch: { url in
                FetchedPage(normalizedHTML: Self.realPageHTML, finalURL: url.absoluteString, contentHash: "h")
            },
            pin: { _, _ in URL(fileURLWithPath: "/tmp/pinned.html") },
            launch: { _ in },
            readResults: { id in
                ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z",
                                    results: [ScoutExtractResult(sourceId: id, verdict: .upcomingListings,
                                                                 events: [event], note: nil)])
            })
    }

    // A sweep of Carnegie's whole feed, by a source with a feed history of its own: the only thing
    // licensed to read a stored show's absence as a cancellation (#801).
    private func carnegieSweep() -> ScoutService.FeedCheck {
        ScoutService.FeedCheck(sourceId: WatchedSource.carnegieId, baseline: 0,
                               successfulCheckCount: WatchedSource.warmupRuns)
    }

    // A real, future Carnegie show, put in the store the way the scout puts it there.
    private func storeACarnegieProspect(in ctx: ModelContext) -> Prospect {
        let carnegie = ExtractedEvent(
            title: "Vienna Philharmonic", presenter: "Vienna Philharmonic",
            venue: "Stern Auditorium / Perelman Stage", performanceDate: "2026-09-19",
            sourceUrl: "https://www.carnegiehall.org/Calendar/2026/09/19/Vienna-Philharmonic-0800PM")
        ScoutService.apply(events: [carnegie], clients: [], history: [], blocked: .empty,
                           feed: carnegieSweep(), today: ScoutTestClock.beforeAllFixtures,
                           sourceIds: [WatchedSource.carnegieId], into: ctx)
        return (try! ctx.fetch(FetchDescriptor<Prospect>())).first { $0.groupName.contains("Vienna") }!
    }

    @Test func confirmingAnUnrelatedLeadDoesNotMarkACarnegieProspectMissed() async throws {
        let ctx = try context()
        let carnegie = storeACarnegieProspect(in: ctx)
        #expect(carnegie.missedScoutCount == 0)

        let lead = ScoutExtractEvent(title: "Brooklyn Youth Chorus", presenter: "Brooklyn Youth Chorus",
                                     venue: "Merkin Hall", performanceDate: "2026-10-03",
                                     sourceUrl: "https://org.example/a")
        let m = model(lead)
        m.urlText = "https://org.example/events"
        await m.start(into: ctx, now: Date(), today: ScoutTestClock.beforeAllFixtures)   // #859: lands it

        // The lead said nothing about Carnegie. Carnegie's show is untouched.
        #expect(carnegie.missedScoutCount == 0)
        #expect(carnegie.disappearedFromFeed == false)
    }

    @Test func twoLeadsInARowDoNotMarkACarnegieProspectDisappeared() async throws {
        let ctx = try context()
        let carnegie = storeACarnegieProspect(in: ctx)

        for i in 0..<2 {
            let lead = ScoutExtractEvent(title: "Brooklyn Youth Chorus \(i)", presenter: "Brooklyn Youth Chorus \(i)",
                                         venue: "Merkin Hall", performanceDate: "2026-10-0\(i + 3)",
                                         sourceUrl: "https://org.example/\(i)")
            let m = model(lead)
            m.urlText = "https://org.example/events-\(i)"
            await m.start(into: ctx, now: Date(), today: ScoutTestClock.beforeAllFixtures)
        }

        #expect(carnegie.missedScoutCount == 0)
        #expect(carnegie.disappearedFromFeed == false)   // the queue would have hidden a live show
    }

    // The scout's own reconcile is untouched. A Carnegie show that really does drop out of Carnegie's
    // feed still accrues its misses and is still marked gone, which is the whole point of #133.
    @Test func aScoutThatNoLongerListsAShowStillMarksItGone() throws {
        let ctx = try context()
        let carnegie = storeACarnegieProspect(in: ctx)

        // Two later scouts, each returning a real feed that no longer carries the Vienna date.
        let stillListed = ExtractedEvent(
            title: "Berlin Philharmonic", presenter: "Berlin Philharmonic",
            venue: "Stern Auditorium / Perelman Stage", performanceDate: "2026-09-26",
            sourceUrl: "https://www.carnegiehall.org/Calendar/2026/09/26/Berlin-Philharmonic-0800PM")
        for _ in 0..<FeedReconcile.goneThreshold {
            // #888 part B: applySweep, the single-source pairing of upsert + reconcile. `apply` alone is
            // now an upsert and reconciles nothing, which is exactly what runNative uses this for.
            ScoutService.applySweep(events: [stillListed], clients: [], history: [], blocked: .empty,
                                    feed: carnegieSweep(), today: ScoutTestClock.beforeAllFixtures,
                                    sourceIds: [WatchedSource.carnegieId], into: ctx)
        }

        #expect(carnegie.missedScoutCount == FeedReconcile.goneThreshold)
        #expect(carnegie.disappearedFromFeed == true)
    }
}
