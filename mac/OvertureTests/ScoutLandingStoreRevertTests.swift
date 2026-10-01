import Testing
import Foundation
import SwiftData

// #4334 (A5): the landing working set's half of putting a failed source back. The revert is the first thing
// on the landing path that deletes (a failed source's pending inserts), so the working set must stop handing
// those rows out, and the reconcile writes an earlier source made, still pending when a later source's save
// fails, must survive the revert of that later source.
@MainActor
@Suite("The landing working set forgets what a failed save put back (#4334)")
struct ScoutLandingStoreRevertTests {
    private func container() throws -> ModelContainer {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        c.mainContext.autosaveEnabled = false
        return c
    }

    private func show(_ key: String, _ title: String, owner: String = "kaufman") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: title, discipline: "theatre", venue: "Callowmere Hall",
                         performanceDate: "2099-09-19", sourceListingURL: "https://\(owner).example/\(key)",
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        p.sourceIds = [owner]
        return p
    }

    // Comment 1 on #4334: a row deleted mid landing was handed back by `rows()` once the save carrying the
    // delete had run, because `isDeleted` reads false again after it. The revert's delete must not be.
    @Test func aRowTheRevertDeletedIsAbsentFromTheWorkingSetAfterTheSave() throws {
        let c = try container()
        let ctx = c.mainContext
        ctx.insert(show("kept", "Kept Show"))
        try ctx.save()
        let landing = ScoutLandingStore(context: ctx)
        _ = try landing.rows()
        let inserted = show("inserted", "Inserted Show")
        ctx.insert(inserted)
        landing.inserted(inserted)
        #expect(try landing.rows().contains { $0 === inserted }, "the insert never joined the working set")
        #expect(try landing.stored(key: "inserted") === inserted)

        let report = landing.revertFailedSave(closing: false)

        #expect(report.insertsDeleted == 1 && report.notRestorable.isEmpty, Comment(rawValue: "\(report)"))
        #expect(try !landing.rows().contains { $0 === inserted }, "the working set handed back a row the revert deleted")
        #expect(try landing.stored(key: "inserted") == nil, "a key the revert freed still answered with the deleted row")
        try ctx.save()
        #expect(try !landing.rows().contains { $0 === inserted }, "after the save the deleted row came back")
        #expect(try landing.rows().map(\.naturalKey) == ["kept"])
        #expect(try ModelContext(c).fetch(FetchDescriptor<Prospect>()).map(\.naturalKey) == ["kept"])
    }

    private func report(_ id: String) -> FeedReconcile.SourceReport {
        FeedReconcile.SourceReport(sourceId: id, seenKeys: [], seenSourceURLs: [], feedCount: 40, baseline: 40,
                                   successfulCheckCount: WatchedSource.warmupRuns, verdict: .upcomingListings)
    }

    // An earlier source's reconcile counted a miss on a show, still pending; a later source wrote the same
    // show and its save failed. The revert puts the later source's writes back and keeps the miss pending
    // for the next save, rather than restoring the committed count and losing it.
    @Test func anEarlierSourcesPendingMissSurvivesALaterSourcesRevert() throws {
        let c = try container()
        let ctx = c.mainContext
        let gone = show("gone", "Wrenfield Players")
        ctx.insert(gone)
        try ctx.save()
        let landing = ScoutLandingStore(context: ctx)
        landing.noteReconcile(FeedReconcile.reconcile(stored: [gone], reports: [report("kaufman")], today: "2026-10-01"))
        #expect(gone.missedScoutCount == 1, "the reconcile counted no miss, so there is nothing to keep")
        // The later source's turn: it writes the same row.
        gone.fitReason = "the failed source's write"
        gone.runSourceURLs = ["https://other.example/run"]

        let reverted = landing.revertFailedSave(closing: false)

        #expect(reverted.notRestorable.isEmpty, Comment(rawValue: "\(reverted)"))
        #expect(gone.fitReason == "r" && gone.runSourceURLs.isEmpty, "the failed source's writes were not put back")
        #expect(gone.missedScoutCount == 1, "the earlier source's pending miss was lost by the later source's revert")
        try ctx.save()
        #expect(try ModelContext(c).fetch(FetchDescriptor<Prospect>()).first?.missedScoutCount == 1)
    }

    // A closing save that fails carries the reconcile itself, so its revert puts the miss back too, and a
    // revert of the reconcile's own record afterwards must not put it back a second time.
    @Test func aClosingRevertPutsTheMissBackOnce() throws {
        let c = try container()
        let ctx = c.mainContext
        let gone = show("gone", "Wrenfield Players")
        gone.missedScoutCount = 2
        ctx.insert(gone)
        try ctx.save()
        let landing = ScoutLandingStore(context: ctx)
        landing.noteReconcile(FeedReconcile.reconcile(stored: [gone], reports: [report("kaufman")], today: "2026-10-01"))
        #expect(gone.missedScoutCount == 3)

        _ = landing.revertFailedSave(closing: true)

        #expect(gone.missedScoutCount == 2)
        #expect(landing.unsavedReconcileWrites.isEmpty, "the reconcile's record outlived the revert that undid it")
        #expect(try ScoutFailedSaveIsolationTests.holdsOnlyWhatTheStoreHolds(ctx, c))
    }

    // The settled sources' writes since the previous save are not this source's turn: they stay pending.
    @Test func aSettledSourcesWritesStayPendingThroughALaterSourcesRevert() throws {
        let c = try container()
        let ctx = c.mainContext
        let settled = WatchedSource(sourceId: "settled", orgName: "Org settled", listingsURL: "https://s.example/",
                                    kind: .html)
        let failing = WatchedSource(sourceId: "failing", orgName: "Org failing", listingsURL: "https://f.example/",
                                    kind: .html)
        ctx.insert(settled)
        ctx.insert(failing)
        try ctx.save()
        let landing = ScoutLandingStore(context: ctx)
        settled.failedReadStreak += 1
        landing.noteSettled(settled)
        failing.notes = "the failed source's note"

        _ = landing.revertFailedSave(closing: false)

        #expect(failing.notes == nil, "the failed source's own write was not put back")
        #expect(settled.failedReadStreak == 1, "a settled source's pending write was put back")
        #expect(try ModelContext(c).fetch(FetchDescriptor<WatchedSource>()).first { $0.sourceId == "settled" }?
                    .failedReadStreak == 0, "the settled write was saved rather than left pending")
    }
}
