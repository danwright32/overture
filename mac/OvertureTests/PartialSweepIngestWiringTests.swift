import Testing
import Foundation
import SwiftData
@testable import Overture

// #887, through the REAL ingest, against the REAL store.
//
// PartialSweepCannotCancelTests proves the RULE. This file proves the rule is WIRED, which is a
// different claim and the one that actually protects Dan.
//
// It exists because severing the wire (hardcoding rejectedCount to 0 in ScoutExtractIngest) left all
// 1,829 tests passing. A guard nobody calls is worth exactly nothing, and this codebase has shipped that
// bug before: a shell guard passed for months while checking the wrong text.
//
// The two tests below are a CONTRAST PAIR and must be read together. The second one is what makes the
// first one mean something: it proves the reconcile really is armed and pointed at this show, so when the
// first one says nothing was cancelled, that is the guard doing its job and not the test failing to
// exercise the path at all.
@MainActor
@Suite("A half-read source cannot cancel, through the real ingest (#887)")
struct PartialSweepIngestWiringTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // A source with a history: past warmup, with a baseline. Exactly the state in which its silence about
    // a show IS allowed to count against that show. Anything less and the reconcile would be disarmed for
    // unrelated reasons and these tests would pass vacuously.
    private func establishedSource(_ ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: "kaufman", orgName: "Kaufman Music Center",
                              listingsURL: "https://kaufman.example/calendar", kind: .html)
        s.pendingContentHash = "new-hash"
        s.hasUnreadChanges = true
        s.successfulCheckCount = WatchedSource.warmupRuns
        // Exactly what the clean run below returns, so that run is at this source's FULL size and the
        // degradation guard is wide open. Set this too high and the reconcile is disarmed for an UNRELATED
        // reason, and the test below passes while proving nothing. That is not hypothetical: it happened on
        // the first run of this file, and only the contrast test caught it.
        //
        // It was 2, which cleared the old floor (minHealthyFraction, 0.5) by exactly one event. #897 raised
        // the bar the reconcile actually asks to isCredibleNewBaseline (0.9), and 1 of 2 no longer clears
        // it: the contrast test went red, which is the same warning the comment above describes, fired for
        // real this time. Now the ONLY thing standing between the partial run and a cancellation is #887's
        // rejected-events guard, which is precisely what this file exists to test.
        s.baselineFeedCount = 1
        ctx.insert(s)
        return s
    }

    // A show this source listed on a previous run, which the current run does NOT list.
    @discardableResult
    private func showItListedLastTime(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "a-show-from-last-time", groupName: "Aurora Strings",
                         discipline: "music", venue: "Merkin Hall", performanceDate: "2099-09-19",
                         sourceListingURL: "https://kaufman.example/aurora", websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        p.sourceIds = ["kaufman"]
        p.missedScoutCount = 0
        ctx.insert(p)
        return p
    }

    private func event(_ title: String, venue: String?) -> ScoutExtractEvent {
        ScoutExtractEvent(title: title, presenter: title, venue: venue,
                          performanceDate: "2099-10-01",
                          sourceUrl: "https://kaufman.example/\(title)")
    }

    private func ingest(_ events: [ScoutExtractEvent], into ctx: ModelContext) {
        let r = ScoutExtractResults(
            version: 1, generatedAt: "2026-07-13T00:00:00Z",
            results: [ScoutExtractResult(sourceId: "kaufman", verdict: .upcomingListings,
                                         events: events, note: nil)])
        ScoutExtractIngest.ingest(r, clients: [], history: [], blocked: [],
                                  today: ScoutTestClock.beforeAllFixtures, now: now, into: ctx)
    }

    // THE BUG. The run read the listings page fine and reported a healthy verdict, but one of its events
    // came back with no venue, which means its detail page was never read. This run does not know what
    // else it failed to reach, so it does not get to conclude that last time's show was cancelled.
    @Test func aRunThatDroppedAnEventDoesNotMarkLastTimesShowAsMissing() throws {
        let ctx = try context()
        establishedSource(ctx)
        let stranded = showItListedLastTime(ctx)

        ingest([event("Kept", venue: "Merkin Hall"),
                event("DetailPageNeverRead", venue: nil)],     // <- dropped by ExtractedEventGuard
               into: ctx)

        #expect(stranded.missedScoutCount == 0)
    }

    // The contrast, and the reason the test above is not vacuous. Same source, same stranded show, same
    // healthy verdict. The ONLY difference is that this run threw nothing away. Now the reconcile is
    // allowed to speak, and it does.
    //
    // If this one ever stops incrementing, the test above has stopped testing anything.
    @Test func aCleanRunDoesMarkLastTimesShowAsMissing() throws {
        let ctx = try context()
        establishedSource(ctx)
        let stranded = showItListedLastTime(ctx)

        ingest([event("Kept", venue: "Merkin Hall")], into: ctx)

        #expect(stranded.missedScoutCount == 1)
    }
}
