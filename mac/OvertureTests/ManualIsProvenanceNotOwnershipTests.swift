import Testing
import Foundation
import SwiftData
@testable import Overture

// #888 part A: a show Dan pasted as a lead was PERMANENTLY immune to ever being marked gone.
//
// The lead path stamps `sourceIds: [WatchedSource.manualId]`, and `manualId` is the string "manual",
// which has no WatchedSource row and therefore never files a report. `everyOwnerWasAskedAndNoneHasIt`
// requires `p.sourceIds.allSatisfy(believable.contains)`, and "manual" can never be in `believable`.
//
// So the show was immune, and it STAYED immune even after a real watched source started listing it,
// because `apply` UNIONS sourceIds on update (#771): the row ends up ["kaufman", "manual"], and the
// "manual" element poisons the allSatisfy forever.
//
// The fix is to say what "manual" actually means. A pasted lead reports on ONE page Dan handed us and
// says nothing whatever about what any venue is still listing (#826). That makes it PROVENANCE (where
// this show came from), not OWNERSHIP (whose feed is answerable for whether it still exists).
//
// This is safe in the direction that matters: it can only ever make a show MORE cancellable, and only
// once a real source that genuinely sweeps a feed has claimed it. A lead-only show stays immune, which
// is #826's whole protection and must not regress.
@MainActor
@Suite("A pasted lead is provenance, not an owner (#888)")
struct ManualIsProvenanceNotOwnershipTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private let today = "2026-07-13"

    @discardableResult
    private func show(_ ctx: ModelContext, sourceIds: [String]) -> Prospect {
        let p = Prospect(naturalKey: "a-show", groupName: "Aurora Strings", discipline: "music",
                         venue: "Merkin Hall", performanceDate: "2099-09-19",
                         sourceListingURL: "https://kaufman.example/aurora", websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        p.sourceIds = sourceIds
        p.missedScoutCount = 0
        ctx.insert(p)
        return p
    }

    // A source that swept its feed cleanly and does NOT list this show. Its silence is evidence.
    private func believableReport(_ sourceId: String) -> FeedReconcile.SourceReport {
        FeedReconcile.SourceReport(
            sourceId: sourceId, seenKeys: ["some-other-show"], seenSourceURLs: [],
            feedCount: 10, baseline: 10,
            successfulCheckCount: WatchedSource.warmupRuns,
            verdict: .upcomingListings, rejectedCount: 0)
    }

    // THE bug. Kaufman swept its calendar, it no longer lists this show, and Kaufman is entirely
    // believable. The show should take a miss. The stray "manual" made that impossible.
    @Test func aLeadShowThatARealSourceNowClaimsCanFinallyBeMarkedGone() throws {
        let ctx = try context()
        let p = show(ctx, sourceIds: ["kaufman", WatchedSource.manualId])

        FeedReconcile.reconcile(stored: [p], reports: [believableReport("kaufman")], today: today)

        #expect(p.missedScoutCount == 1)
    }

    // #826's protection, which must NOT regress. A show that only ever came from a page Dan pasted has no
    // feed answerable for it. Nobody swept anything that would prove it gone, so nothing may take it away,
    // no matter which other sources ran this scout.
    @Test func aShowThatOnlyEverCameFromAPastedLeadStaysImmune() throws {
        let ctx = try context()
        let p = show(ctx, sourceIds: [WatchedSource.manualId])

        FeedReconcile.reconcile(stored: [p], reports: [believableReport("kaufman")], today: today)

        #expect(p.missedScoutCount == 0)
    }

    // A show with NO sources at all (created by Prep, or predating #800) is likewise nobody's to take
    // away. allSatisfy is vacuously true of an empty list, so this guard is load-bearing.
    @Test func aShowNobodyClaimsStaysImmune() throws {
        let ctx = try context()
        let p = show(ctx, sourceIds: [])

        FeedReconcile.reconcile(stored: [p], reports: [believableReport("kaufman")], today: today)

        #expect(p.missedScoutCount == 0)
    }

    // Stripping "manual" must not accidentally lower the bar for the REAL owners. Kaufman ran and is
    // believable, but this show is also claimed by merkin, which was not asked at all this run. Merkin
    // might still be listing it. Nothing may be concluded.
    @Test func strippingManualDoesNotExcuseARealOwnerThatWasNeverAsked() throws {
        let ctx = try context()
        let p = show(ctx, sourceIds: ["kaufman", "merkin", WatchedSource.manualId])

        FeedReconcile.reconcile(stored: [p], reports: [believableReport("kaufman")], today: today)

        #expect(p.missedScoutCount == 0)
    }

    // And presence still works from any direction: a source that DOES list it proves it alive and resets
    // the counter, regardless of provenance.
    @Test func anySourceStillListingItProvesItAlive() throws {
        let ctx = try context()
        let p = show(ctx, sourceIds: ["kaufman", WatchedSource.manualId])
        p.missedScoutCount = 1

        var report = believableReport("kaufman")
        report.seenKeys = ["a-show"]
        FeedReconcile.reconcile(stored: [p], reports: [report], today: today)

        #expect(p.missedScoutCount == 0)
    }
}
