import Testing
import Foundation
import SwiftData

// #1027 Phase 3: a page Dan confirmed as right-but-empty stops nagging, until its bytes change.
//
// The suppression is reached at ingest time: a no_dated_content result whose just-read hash still equals
// the confirmed hash is recorded as a benign confirmed-empty, not a failure. The realistic path that
// gets there is exercised in full below (confirm, a later non-empty read that moves the ingested hash
// forward, then the page returns to the confirmed-empty bytes), because a suppression branch that only
// passes because it never runs is worth nothing.
@MainActor
@Suite("A confirmed-empty page is suppressed until it changes (#1027)")
struct ScoutExtractConfirmSuppressionTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func results(_ verdict: PageVerdict, events: [ScoutExtractEvent] = []) -> ScoutExtractResults {
        ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z",
                            results: [ScoutExtractResult(sourceId: "org", verdict: verdict,
                                                         events: events, note: nil)])
    }

    private func ingest(_ r: ScoutExtractResults, into ctx: ModelContext) -> ScoutService.Outcome {
        ScoutExtractIngest.ingest(r, clients: [], history: [], blocked: .empty,
                                  today: ScoutTestClock.beforeAllFixtures, now: now, into: ctx)
    }

    // The realistic full path (red-team #4): confirm at H_empty, then the page grows real shows (a
    // successful read moves the ingested hash forward), then it goes quiet again at exactly H_empty.
    @Test func aReadThatReturnsToTheConfirmedEmptyBytesIsSuppressed() throws {
        let ctx = try context()
        let s = WatchedSource(sourceId: "org", orgName: "Org",
                              listingsURL: "https://org.example/events", kind: .html)
        s.confirmedEmptyHash = "H_empty"
        s.lastContentHash = "H_empty"
        ctx.insert(s)
        try ctx.save()

        // The page grows a real show: a successful read promotes lastContentHash to H_shows.
        s.pendingContentHash = "H_shows"
        s.hasUnreadChanges = true
        _ = ingest(results(.upcomingListings, events: [
            ScoutExtractEvent(title: "A Concert", presenter: "A Concert", venue: "Merkin Hall",
                              performanceDate: "2099-09-19", sourceUrl: "https://org.example/a")]), into: ctx)
        #expect(s.lastContentHash == "H_shows")
        #expect(s.confirmedEmptyHash == "H_empty")   // the confirmation survives an unrelated read

        // The page returns to the exact confirmed-empty bytes.
        s.pendingContentHash = "H_empty"
        s.hasUnreadChanges = true
        let outcome = ingest(results(.noDatedContent), into: ctx)

        #expect(outcome.failedSources.isEmpty)       // NOT nagged
        #expect(s.health == .ok)                     // not marked failing
        #expect(s.lastFailure == nil)
        #expect(s.hasUnreadChanges == false)         // accepted; nothing left to read
        #expect(s.lastContentHash == "H_empty")      // ingested hash tracks the accepted bytes
    }

    // The other direction, through the same real path: a confirmed page whose bytes have CHANGED is a
    // failure again. The confirmation was for specific bytes, not forever.
    @Test func aChangedPageNagsAgainDespiteAPriorConfirmation() throws {
        let ctx = try context()
        let s = WatchedSource(sourceId: "org", orgName: "Org",
                              listingsURL: "https://org.example/events", kind: .html)
        s.confirmedEmptyHash = "H_empty"
        s.lastContentHash = "H_empty"
        s.pendingContentHash = "H_different"          // the page changed since Dan confirmed
        s.hasUnreadChanges = true
        ctx.insert(s)
        try ctx.save()

        let outcome = ingest(results(.noDatedContent), into: ctx)

        #expect(outcome.failedSources.count == 1)     // nags again
        #expect(s.health == .failing)
        #expect(s.lastFailure == .verdict(.noDatedContent))
    }
}
