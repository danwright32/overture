import Testing
import Foundation
import SwiftData

// #897, through the REAL ingest, against the REAL store.
//
// SweepCoverageTests proves the RULE. This file proves the rule is WIRED into the reconcile, which is a
// different claim and the one that actually protects Dan's live shows. It exists because this codebase has
// shipped a guard nobody called before (severing PartialSweep's wire left 1,829 tests green), so a rule
// that is not exercised end to end is worth nothing.
//
// The two headline tests are a CONTRAST PAIR and must be read together. The clean-sweep test is what makes
// the short-sweep test mean something: it proves the reconcile really is armed and pointed at this show,
// so when the short sweep marks nothing gone, that is the guard doing its job and not the test failing to
// exercise the path. The ONLY difference between them is whether the run read the fourth stitched month.
@MainActor
@Suite("A short stitched sweep cannot cancel, through the real ingest (#897)")
struct StitchedSweepIngestWiringTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let stitchedMonths = ["2026-07", "2026-08", "2026-09", "2026-10"]

    // A source mid-way through reading a FOUR-month stitched page (#858): warmed up, with a baseline, its
    // pending hash set and its stitched-month expectation recorded, exactly the state ScoutService.check
    // leaves it in just before the run reads. Baseline 1 against a 1-event clean run so the size gate is
    // wide open and the only thing that can disarm cancellation is this sweep-coverage wire.
    private func establishedStitchedSource(_ ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: "kaufman", orgName: "Kaufman Music Center",
                              listingsURL: "https://kaufman.example/calendar", kind: .html)
        s.pendingContentHash = "new-hash"
        s.pendingPageMonths = stitchedMonths
        s.hasUnreadChanges = true
        s.successfulCheckCount = WatchedSource.warmupRuns
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

    private func event(_ title: String) -> ScoutExtractEvent {
        ScoutExtractEvent(title: title, presenter: title, venue: "Merkin Hall",
                          performanceDate: "2099-10-01",
                          sourceUrl: "https://kaufman.example/\(title)")
    }

    private func ingest(monthsCovered: [String], into ctx: ModelContext) {
        let r = ScoutExtractResults(
            version: 3, generatedAt: "2026-07-13T00:00:00Z",
            results: [ScoutExtractResult(sourceId: "kaufman", verdict: .upcomingListings,
                                         events: [event("Kept")], note: nil,
                                         monthsCovered: monthsCovered)])
        ScoutExtractIngest.ingest(r, clients: [], history: [], blocked: .empty,
                                  today: ScoutTestClock.beforeAllFixtures, now: now, into: ctx)
    }

    // THE BUG. The run reported a healthy upcoming_listings verdict, but it only read three of the four
    // months the app stitched into the pin. It returned fewer shows, not because the calendar shrank but
    // because it never looked at October, and it does not get to conclude last time's show was cancelled.
    @Test func aRunThatMissedAStitchedMonthDoesNotMarkLastTimesShowAsMissing() throws {
        let ctx = try context()
        establishedStitchedSource(ctx)
        let stranded = showItListedLastTime(ctx)

        ingest(monthsCovered: ["2026-07", "2026-08", "2026-09"], into: ctx)   // missed October

        #expect(stranded.missedScoutCount == 0)
    }

    // The contrast, and the reason the test above is not vacuous. Same source, same stranded show, same
    // healthy verdict, same single returned event. The ONLY difference is that this run read all four
    // stitched months, so the reconcile is armed and it marks the missing show gone.
    //
    // If this one ever stops incrementing, the test above has stopped testing anything.
    @Test func aRunThatReadEveryStitchedMonthDoesMarkLastTimesShowAsMissing() throws {
        let ctx = try context()
        establishedStitchedSource(ctx)
        let stranded = showItListedLastTime(ctx)

        ingest(monthsCovered: stitchedMonths, into: ctx)   // read all four

        #expect(stranded.missedScoutCount == 1)
    }

    // #897: a short sweep must record NO health and must NOT stamp the page as finished, mirroring the
    // partial-read path (#1012): the hash stays pending so the next scout re-reads, the unread flag stays
    // set, and the warmup counter does not advance on a page that was not read in full.
    @Test func aShortSweepRecordsNoHealthAndLeavesThePageUnfinished() throws {
        let ctx = try context()
        let source = establishedStitchedSource(ctx)
        showItListedLastTime(ctx)

        ingest(monthsCovered: ["2026-07", "2026-08", "2026-09"], into: ctx)   // missed October

        #expect(source.pendingContentHash == "new-hash")            // hash NOT promoted
        #expect(source.lastContentHash == nil)                      // page not marked finished
        #expect(source.hasUnreadChanges)                            // next scout re-reads
        #expect(source.successfulCheckCount == WatchedSource.warmupRuns)  // warmup did not advance
    }

    // The contrast for health: a full sweep DOES finish the page. Proves the assertions above are the
    // short sweep being held back, not the ingest failing to record anything at all.
    @Test func aFullSweepFinishesThePageAndAdvancesWarmup() throws {
        let ctx = try context()
        let source = establishedStitchedSource(ctx)
        showItListedLastTime(ctx)

        ingest(monthsCovered: stitchedMonths, into: ctx)   // read all four

        #expect(source.lastContentHash == "new-hash")               // page finished, hash promoted
        #expect(source.pendingContentHash == nil)
        #expect(!source.hasUnreadChanges)
        #expect(source.pendingPageMonths.isEmpty)                   // expectation spent
        #expect(source.successfulCheckCount == WatchedSource.warmupRuns + 1)
    }
}
