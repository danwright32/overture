import Testing
import Foundation
import SwiftData

// #876: a Prep run that comes back with fewer shows than it was given.
//
// If the run returns results for 3 of the 5 shows queued, the app ingests the 3 and says NOTHING about
// the other 2. They keep their un-drafted state, so the next run picks them up again and nothing is lost.
// But Dan is never told they were dropped, so a show can sit in "ready to prep" across two or three runs
// with no explanation, and a show the model chokes on EVERY time would be retried forever in silence. The
// only symptom is a Prep pill whose count never quite goes down.
//
// Self-healing is not the same as visible.
//
// The app WROTE the queue, so it already knows what it asked for. This is that comparison. Deliberately
// app-side: synthesizing an empty prep result script-side would CLAIM the run researched a show and found
// nobody, about a show nobody ever looked at (#868).
@MainActor
@Suite("A Prep run that comes back short says so (#876)")
struct PrepShortfallTests {

    private let queued = Date(timeIntervalSince1970: 1_000_000)
    private let answered = Date(timeIntervalSince1970: 1_000_600)   // ten minutes later

    // --- The rule, in isolation ----------------------------------------------------------------

    @Test func aRunThatAnswersEveryShowIsShort0() {
        let missing = HandoffShortfall.missingKeys(queuedKeys: ["a", "b"], answeredKeys: ["a", "b"],
                                                queueGeneratedAt: queued, resultsModifiedAt: answered)
        #expect(missing.isEmpty)
    }

    @Test func aRunThatAnswers3Of5NamesTheOther2() {
        let missing = HandoffShortfall.missingKeys(queuedKeys: ["a", "b", "c", "d", "e"],
                                                answeredKeys: ["a", "c", "e"],
                                                queueGeneratedAt: queued, resultsModifiedAt: answered)
        #expect(missing == ["b", "d"])
    }

    // THE guard, and the reason this issue was not a one-liner. startPrep writes a FRESH queue but leaves
    // the PREVIOUS run's results file on disk. So a run that dies without ever writing results (#868's
    // exact case) leaves a new queue sitting beside stale results. Diffing those two would announce that
    // every show the run was given had been dropped, about a run that never even started work.
    //
    // A warning that cries wolf is worse than no warning. Results that predate the queue cannot be an
    // answer to it, so they are not treated as one. The dead run is already reported on its own path.
    @Test func resultsOlderThanTheQueueAreNotAnAnswerToItAndRaiseNoAlarm() {
        let staleResults = queued.addingTimeInterval(-60)   // written BEFORE the queue was even built

        let missing = HandoffShortfall.missingKeys(queuedKeys: ["a", "b", "c"], answeredKeys: [],
                                                queueGeneratedAt: queued, resultsModifiedAt: staleResults)

        #expect(missing.isEmpty)
    }

    // We cannot know what was asked, so we must not claim anything was dropped. Never invent a shortfall.
    @Test func anUnknownQueueRaisesNoAlarm() {
        #expect(HandoffShortfall.missingKeys(queuedKeys: [String](), answeredKeys: [],
                                          queueGeneratedAt: nil, resultsModifiedAt: answered).isEmpty)
        #expect(HandoffShortfall.missingKeys(queuedKeys: ["a"], answeredKeys: [],
                                          queueGeneratedAt: nil, resultsModifiedAt: answered).isEmpty)
    }

    // Same reasoning from the other side: no readable results file means no run to report a shortfall for.
    @Test func anUnknownResultsFileRaisesNoAlarm() {
        #expect(HandoffShortfall.missingKeys(queuedKeys: ["a"], answeredKeys: [],
                                          queueGeneratedAt: queued, resultsModifiedAt: nil).isEmpty)
    }

    // A run that answers a show it was never given is a DIFFERENT failure (Outcome.unmatchedKeys), and
    // must not quietly cancel out a show that genuinely went missing.
    @Test func anExtraAnswerNeverMasksAShowThatWentMissing() {
        let missing = HandoffShortfall.missingKeys(queuedKeys: ["a", "b"], answeredKeys: ["a", "zzz"],
                                                queueGeneratedAt: queued, resultsModifiedAt: answered)
        #expect(missing == ["b"])
    }

    // --- Through the importer, against real files ----------------------------------------------

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func prospect(_ ctx: ModelContext, key: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Aurora Strings", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2099-09-19",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        ctx.insert(p)
        return p
    }

    // Every file is written into a TEMP directory with an explicit URL. A test that reaches for a default
    // handoff path writes into the LIVE Debug store's directory and can leave a fake work-list on disk for
    // a real detached run to pick up.
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prep-shortfall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeQueue(_ keys: [String], to dir: URL, generatedAt: String) throws -> URL {
        let items = keys.map {
            PrepQueueItem(naturalKey: $0, groupName: "Aurora Strings", venue: "Weill Recital Hall",
                          performanceDate: "2099-09-19", discipline: "music", websiteURL: nil,
                          sourceListingURL: nil, possibleMatchName: nil, priorRelationship: "none",
                          production: "self")
        }
        let url = dir.appendingPathComponent("overture-prep-queue.json")
        try PrepQueueBuilder.encode(PrepQueue(version: PrepQueueBuilder.version,
                                              generatedAt: generatedAt, items: items)).write(to: url)
        return url
    }

    private func writeResults(_ keys: [String], to dir: URL) throws -> URL {
        let results = PrepResults(version: 2, generatedAt: "2026-07-13T00:10:00Z",
                                  results: keys.map {
                                      PrepResult(naturalKey: $0,
                                                 draft: PrepDraft(subject: "Photographs of your concert",
                                                                  body: "Hello, I photograph performances.",
                                                                  variant: "rate_stated"))
                                  })
        let url = dir.appendingPathComponent("overture-prep-results.json")
        try JSONEncoder().encode(results).write(to: url)
        return url
    }

    @Test func theImporterNamesTheShowsThatNeverCameBack() throws {
        let ctx = try context()
        for k in ["a", "b", "c"] { prospect(ctx, key: k) }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The queue was built an hour ago; the results landed just now, so they answer it.
        let queueURL = try writeQueue(["a", "b", "c"], to: dir,
                                      generatedAt: ISO8601DateFormatter().string(
                                        from: Date().addingTimeInterval(-3600)))
        let resultsURL = try writeResults(["a", "c"], to: dir)

        let outcome = try PrepImporter.ingestFile(at: resultsURL, into: ctx, queueURL: queueURL)

        #expect(outcome.drafted == 2)
        #expect(outcome.missingKeys == ["b"])
    }

    @Test func aFullRunNamesNobody() throws {
        let ctx = try context()
        for k in ["a", "b"] { prospect(ctx, key: k) }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let queueURL = try writeQueue(["a", "b"], to: dir,
                                      generatedAt: ISO8601DateFormatter().string(
                                        from: Date().addingTimeInterval(-3600)))
        let resultsURL = try writeResults(["a", "b"], to: dir)

        let outcome = try PrepImporter.ingestFile(at: resultsURL, into: ctx, queueURL: queueURL)

        #expect(outcome.drafted == 2)
        #expect(outcome.missingKeys.isEmpty)
    }

    // The cry-wolf case, end to end: a queue generated AFTER the results on disk (a run that died without
    // writing anything, leaving the previous run's results behind). Nothing was dropped by this queue's
    // run, because this queue's run never produced anything at all.
    @Test func aQueueNewerThanTheResultsOnDiskRaisesNoAlarm() throws {
        let ctx = try context()
        for k in ["x", "y", "z"] { prospect(ctx, key: k) }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let resultsURL = try writeResults(["old"], to: dir)          // last run's leftovers
        // This queue was built one hour into the FUTURE relative to those results.
        let queueURL = try writeQueue(["x", "y", "z"], to: dir,
                                      generatedAt: ISO8601DateFormatter().string(
                                        from: Date().addingTimeInterval(3600)))

        let outcome = try PrepImporter.ingestFile(at: resultsURL, into: ctx, queueURL: queueURL)

        #expect(outcome.missingKeys.isEmpty)   // never "3 didn't come back" about a run that never ran
    }

    // A missing queue file means we have no record of what was asked. Ingest Dan's drafts anyway; a gap in
    // our own bookkeeping is never a reason to drop his work or to invent a failure.
    @Test func aMissingQueueFileStillLandsTheDraftsAndClaimsNothing() throws {
        let ctx = try context()
        prospect(ctx, key: "a")
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let resultsURL = try writeResults(["a"], to: dir)
        let absentQueue = dir.appendingPathComponent("no-such-queue.json")

        let outcome = try PrepImporter.ingestFile(at: resultsURL, into: ctx, queueURL: absentQueue)

        #expect(outcome.drafted == 1)
        #expect(outcome.missingKeys.isEmpty)
    }
}
