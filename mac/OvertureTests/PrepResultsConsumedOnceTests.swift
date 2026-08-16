import Testing
import Foundation
import SwiftData

// #884. A Prep results file is consumed ONCE.
//
// `ingestPrep()` runs on every launch against whatever `overture-prep-results.json` is still sitting on
// disk, and that file is never deleted. The importer is idempotent about the DATA it writes, which is why
// this looked safe. It is not, and re-reading an old run does three separate kinds of harm:
//
//   1. The shortfall re-announces. "2 didn't come back, they'll be retried" reappears every launch, about
//      a run that may be days old, long after those shows were re-prepped. A warning Dan sees every day is
//      a warning he learns to ignore, which defeats the whole point of #876. Same for "2 didn't match".
//   2. The good news re-announces. `drafted` is NOT idempotent to zero: nothing in `ingest` checks whether
//      a prospect was already drafted, so it re-applies the draft and counts it again, every launch.
//   3. IT UN-APPROVES DAN'S WORK. This is the one that matters. `ingest` pushes a prospect's status back
//      to `.drafted` from `.approved` (deliberately, for a REAL redraft: #367 says changed text must be
//      re-reviewed), and `draftBlockedBySend` only protects a prospect that has already been SENT. So an
//      approved, not-yet-sent draft is silently knocked back to "needs review" on the next launch. Dan
//      approves a draft, quits, reopens, and his approval is quietly gone.
//
// One root cause, so one fix: a results file the app has already consumed is not consumed again.
@MainActor
@Suite("A Prep results file is consumed once, not re-read on every launch (#884)")
struct PrepResultsConsumedOnceTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "PrepConsumedOnce-\(UUID().uuidString)")!
    }

    @discardableResult
    private func keptProspect(_ ctx: ModelContext, key: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Choir", discipline: "choral", venue: "Stern",
                         performanceDate: "2026-06-24", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private let key = Prospect.makeNaturalKey(groupName: "Choir", performanceDate: "2026-06-24",
                                              venue: "Stern")

    // Writes a real results file, because the fingerprint is taken over the bytes on disk.
    private func writeResults(subject: String, generatedAt: String = "2026-07-13T10:00:00Z") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prep-results-\(UUID().uuidString).json")
        let results = PrepResults(version: 2, generatedAt: generatedAt, results: [
            PrepResult(naturalKey: key, contacts: nil,
                       draft: PrepDraft(subject: subject, body: "Hi there", variant: "A")),
        ])
        try JSONEncoder().encode(results).write(to: url)
        return url
    }

    // The normal case still works: a run finishes, its results are consumed, Dan gets his draft.
    @Test func aResultsFileTheAppHasNotSeenIsConsumed() throws {
        let ctx = try context()
        keptProspect(ctx, key: key)
        let url = try writeResults(subject: "Photographing your performance")

        let outcome = PrepImporter.consumeIfNew(slot: .prep, at: url, into: ctx, defaults: defaults())

        #expect(outcome?.drafted == 1)
    }

    // THE ONE THAT MATTERS. Dan approves a draft, quits, and reopens the app.
    //
    // Today the old results file is re-read, the draft is re-applied, and his approval is silently gone:
    // the prospect is back in "needs review" with no error and nothing said. He would have to notice, on
    // his own, that a decision he made yesterday had been undone.
    @Test func aRelaunchCannotUnApproveADraftDanAlreadyApproved() throws {
        let ctx = try context()
        let p = keptProspect(ctx, key: key)
        let url = try writeResults(subject: "Photographing your performance")
        let store = defaults()

        PrepImporter.consumeIfNew(slot: .prep, at: url, into: ctx, defaults: store)   // the run lands
        p.status = .approved                                             // Dan approves it
        try ctx.save()

        PrepImporter.consumeIfNew(slot: .prep, at: url, into: ctx, defaults: store)   // he quits and reopens

        #expect(p.status == .approved)
    }

    // The stale summary, which is what #884 was filed about. A file already consumed produces no outcome
    // at all, so there is nothing to build a note from: no "2 didn't come back" about a run from Tuesday,
    // and no "5 drafted" about drafts he has been looking at for days.
    @Test func aResultsFileAlreadyConsumedIsNotConsumedAgain() throws {
        let ctx = try context()
        keptProspect(ctx, key: key)
        let url = try writeResults(subject: "Photographing your performance")
        let store = defaults()

        PrepImporter.consumeIfNew(slot: .prep, at: url, into: ctx, defaults: store)

        #expect(PrepImporter.consumeIfNew(slot: .prep, at: url, into: ctx, defaults: store) == nil)
    }

    // ...and the NEXT run still lands. Consuming once must not mean consuming never: a fresh results file
    // is different bytes, so it is a different file, and it is read.
    @Test func theNextRunsResultsAreStillConsumed() throws {
        let ctx = try context()
        let p = keptProspect(ctx, key: key)
        let store = defaults()

        PrepImporter.consumeIfNew(slot: .prep, at: try writeResults(subject: "First try"), into: ctx, defaults: store)
        let second = PrepImporter.consumeIfNew(slot: .prep, 
            at: try writeResults(subject: "A better subject line", generatedAt: "2026-07-14T10:00:00Z"),
            into: ctx, defaults: store)

        #expect(second?.drafted == 1)
        #expect(p.draftSubject == "A better subject line")
    }

    // THE FAILURE PATH. The ingest ran but the store refused to save, so nothing Dan can see actually
    // landed. That file must NOT be marked consumed, or the one retry that would have rescued his drafts
    // is skipped forever and the run's work is lost in silence.
    @Test func aResultsFileWhoseSaveFailedIsRetriedRatherThanMarkedConsumed() throws {
        let ctx = try context()
        keptProspect(ctx, key: key)
        let url = try writeResults(subject: "Photographing your performance")
        let store = defaults()

        var outcome = PrepImporter.Outcome()
        outcome.saveFailed = true
        let failed = PrepImporter.consumeIfNew(slot: .prep, at: url, into: ctx, defaults: store,
                                               ingest: { _, _ in outcome })
        #expect(failed?.saveFailed == true)

        // The real importer, on the next launch. It must still get its turn.
        #expect(PrepImporter.consumeIfNew(slot: .prep, at: url, into: ctx, defaults: store)?.drafted == 1)
    }

    // No results file at all (a fresh install, or a run that never wrote one). Silent, and no crash.
    @Test func noResultsFileIsSimplyNothingToDo() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("prep-results-\(UUID().uuidString).json")

        #expect(PrepImporter.consumeIfNew(slot: .prep, at: missing, into: try context(), defaults: defaults()) == nil)
    }

    // THE WIRE, which is a separate claim from the guard above.
    //
    // Every test in this suite calls `consumeIfNew` directly, so all of them stay green if `ingestPrep()`
    // goes back to calling `ingestFile` and re-reads the old file on every launch. The bug would be back
    // and the suite would not notice. `ingestPrep` lives inside a SwiftUI view, where no test can reach it
    // (#885), so the wire is held by a source guard, which is this project's existing convention for
    // exactly this shape (see PrepProgressWiringGuardTests).
    @Test func theLaunchIngestGoesThroughConsumeIfNew() {
        let rootView = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(!rootView.isEmpty)

        guard let body = rootView.range(of: "private func ingestPrep()") else {
            Issue.record("ingestPrep not found in RootView")
            return
        }
        let fn = rootView[body.lowerBound...].prefix(900)
        #expect(fn.contains("PrepImporter.consumeIfNew(slot: .prep, into: context)"))
        // The old, unguarded call. It re-read the results file on every launch, and it must not come back.
        #expect(!fn.contains("PrepImporter.ingestFile("))
    }
}
