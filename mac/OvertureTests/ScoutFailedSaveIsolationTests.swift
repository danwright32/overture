import Testing
import Foundation
import SwiftData

// #4334 (A5): a scout source whose save fails is PUT BACK, so it cannot block later saves.
//
// WHAT WAS WRONG. A source's save that failed left everything it wrote pending in the main context (#499
// said so and stopped there). The next save, a later source's, the closing save or Dan's own, then carried
// the failed source's writes anyway, or failed on them again, so one bad source blocked every save after
// it; and a landing offered again applied its captured writes a second time on top of the pending first.
//
// HOW IT IS READ. Autosave is off. Each failure is injected through the landing's own save seams
// (`saveSource`, `saveEntry`, `saveClosing`), because a real refusal that can be switched off on the same
// context does not exist (`FailurePathRevertProbeTests` measured each candidate). The store is read through
// a FRESH context, which sees only what was saved, so "a later save succeeds" is a save that really ran.
@MainActor
@Suite("A scout source whose save fails is put back and cannot block later saves (#4334)")
final class ScoutFailedSaveIsolationTests {
    private let now = Date()
    private let sandboxes = TemporarySandboxes()
    private struct SaveRefused: Error {}

    private func container() throws -> ModelContainer {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        c.mainContext.autosaveEnabled = false
        return c
    }

    private func night(_ n: Int) -> String {
        ScoutTestClock.day(30 + n, after: now)
    }

    // An html source with a page read and waiting to land. Invented names (L155).
    @discardableResult
    private func html(_ id: String, in ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: "Org \(id)", listingsURL: "https://\(id).example/events",
                              kind: .html)
        s.venueLocation = "New York, NY"
        s.lastContentHash = "old"
        s.pendingContentHash = "new-\(id)"
        s.hasUnreadChanges = true
        ctx.insert(s)
        return s
    }

    private func result(_ id: String, titles: [String]? = nil) -> ScoutExtractResult {
        let names = titles ?? (0..<2).map { "Recital \(id) \($0)" }
        return ScoutExtractResult(sourceId: id, verdict: .upcomingListings, events: names.enumerated().map { k, title in
            ScoutExtractEvent(title: title, presenter: title, venue: "Merkin Hall", performanceDate: night(k),
                              sourceUrl: "https://\(id).example/\(k)")
        }, note: "read \(id)")
    }

    private func results(_ items: [ScoutExtractResult]) -> ScoutExtractResults {
        ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z", results: items)
    }

    private func ingest(_ r: ScoutExtractResults, into ctx: ModelContext, sequence: Int? = nil,
                        saveSource: @escaping (ModelContext) throws -> Void = { try $0.save() },
                        saveEntry: @escaping (ModelContext) throws -> Void = { try $0.save() },
                        saveClosing: @escaping (ModelContext) throws -> Void = { try $0.save() },
                        classify: @escaping (Error) -> LandingSaveFailure.Scope = LandingSaveFailure.classify,
                        journals: LandingJournals? = nil)
        async -> ScoutService.Outcome {
        await ScoutExtractIngest.ingest(r, clients: [], history: [], blocked: .empty,
                                        today: ScoutTestClock.beforeAllFixtures, now: now,
                                        landings: LandingSingleFlight(sleep: { _ in }),
                                        sequence: sequence, sequenceFloor: { 0 },
                                        saveClosing: saveClosing, saveSource: saveSource, saveEntry: saveEntry,
                                        classifySaveFailure: classify, journals: journals, into: ctx)
    }

    // The save of the source whose own row it is carrying fails; every other save goes through. What the
    // failing source had written by then is recorded, so a test can prove it wrote something (L159).
    private final class FailOne {
        let sourceId: String
        private(set) var calls = 0
        private(set) var refused = 0
        private(set) var pendingAtRefusal: (changed: Int, inserted: Int) = (0, 0)
        private(set) var changedAtRefusal: [String] = []
        var beforeThrowing: (ModelContext) -> Void = { _ in }
        init(_ sourceId: String) { self.sourceId = sourceId }

        func save(_ ctx: ModelContext) throws {
            calls += 1
            // Only the FIRST such save: once the source is put back its row can still read as changed (back
            // to the values it already had), and a later source's save carrying it is not the failed one.
            if refused == 0, ctx.changedModelsArray.contains(where: { ($0 as? WatchedSource)?.sourceId == sourceId }) {
                refused += 1
                pendingAtRefusal = (ctx.changedModelsArray.count, ctx.insertedModelsArray.count)
                changedAtRefusal = ctx.changedModelsArray.compactMap { ($0 as? Prospect)?.groupName }
                beforeThrowing(ctx)
                throw SaveRefused()
            }
            try ctx.save()
        }
    }

    // What a later save would carry of a put back landing: nothing that differs from the store. Not
    // `!hasChanges`, which a revert cannot give: a field written back to its committed value still reads as
    // changed (`LandingSaveFailureTests.aFieldWrittenBackStillReadsAsChanged`), so the honest question is
    // whether the context, read through itself, holds exactly what the store holds, with no pending insert
    // or delete (the method `FailurePathRevertProbeTests` uses).
    static func holdsOnlyWhatTheStoreHolds(_ ctx: ModelContext, _ c: ModelContainer) throws -> Bool {
        let held = try FailurePathRevertProbeTests.snapshot(ctx)
        let stored = try FailurePathRevertProbeTests.snapshot(ModelContext(c))
        return ctx.insertedModelsArray.isEmpty && ctx.deletedModelsArray.isEmpty && held == stored
    }

    private func titles(_ c: ModelContainer) throws -> [String] {
        try ModelContext(c).fetch(FetchDescriptor<Prospect>()).map(\.groupName).sorted()
    }

    private func states(_ o: ScoutService.Outcome) -> [String: ScoutService.SourceResult.State] {
        Dictionary(o.sources.map { ($0.sourceId, $0.state) }, uniquingKeysWith: { $1 })
    }

    // MARK: - A source level failure: the source is put back, and the landing carries on

    @Test func aSourceLevelFailurePutsTheSourceBackAndTheLaterSourcesLand() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b", "c"] { html(id, in: ctx) }
        try ctx.save()
        let before = try FailurePathRevertProbeTests.snapshot(ModelContext(c))
        let failing = FailOne("b")

        let outcome = await ingest(results([result("a"), result("b"), result("c")]), into: ctx,
                                   saveSource: failing.save, classify: { _ in .source })

        #expect(failing.refused == 1 && failing.pendingAtRefusal.inserted >= 2, Comment(rawValue:
            "b's save was not refused while it carried b's shows, so nothing here failed: \(failing.pendingAtRefusal)"))
        let s = states(outcome)
        #expect(s["a"] == .ingested(found: 2) && s["c"] == .ingested(found: 2), Comment(rawValue: "\(s)"))
        #expect(s["b"] == .saveFailed, Comment(rawValue: "the failed source was reported as \(String(describing: s["b"]))"))
        #expect(outcome.saveFailed)
        #expect(outcome.landingStop == nil, "a source level failure stopped the landing")
        #expect(outcome.sources.filter { if case .ingested = $0.state { return true }; return false }.count == 2)
        #expect(!ctx.hasChanges, Comment(rawValue:
            "the landing returned with \(ctx.changedModelsArray.count + ctx.insertedModelsArray.count) rows pending"))

        // A LATER save, and what the store then holds: b exactly as it was before apply, a and c landed.
        try ctx.save()
        let after = try FailurePathRevertProbeTests.snapshot(ModelContext(c))
        #expect(after["WatchedSource b"] == before["WatchedSource b"], Comment(rawValue:
            "the failed source's row was not put back: \(after["WatchedSource b"] ?? []) against \(before["WatchedSource b"] ?? [])"))
        let stored = try titles(c)
        #expect(!stored.contains { $0.contains("Recital b") }, Comment(rawValue: "b's shows reached the store: \(stored)"))
        #expect(stored.filter { $0.contains("Recital a") || $0.contains("Recital c") }.count == 4,
                Comment(rawValue: "the sources after the failure did not land whole: \(stored)"))
        #expect(try ModelContext(c).fetch(FetchDescriptor<WatchedSource>()).first { $0.sourceId == "c" }?.lastContentHash
                == "new-c", "the source after the failure was not marked read")
    }

    // MARK: - A store level failure: the landing stops, and leaves nothing pending

    @Test func aStoreLevelFailureStopsTheLandingAndLeavesNothingPending() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b", "c"] { html(id, in: ctx) }
        try ctx.save()
        let before = try FailurePathRevertProbeTests.snapshot(ModelContext(c))
        let failing = FailOne("b")

        let outcome = await ingest(results([result("a"), result("b"), result("c")]), into: ctx,
                                   saveSource: failing.save)

        let s = states(outcome)
        #expect(s["a"] == .ingested(found: 2), Comment(rawValue: "\(s)"))
        #expect(s["b"] == .saveFailed)
        #expect(s["c"] == .notAttempted, Comment(rawValue:
            "the source after a store level failure was reported as \(String(describing: s["c"]))"))
        #expect(outcome.saveFailed)
        #expect(outcome.landingStop == .storeRefusedASave(source: "Org b"), Comment(rawValue:
            "\(String(describing: outcome.landingStop))"))
        #expect(failing.calls == 2, "a source after the store refused a save was still attempted")
        #expect(!ctx.hasChanges, "the stopped landing left writes pending")
        let after = try FailurePathRevertProbeTests.snapshot(ModelContext(c))
        #expect(after["WatchedSource b"] == before["WatchedSource b"])
        #expect(after["WatchedSource c"] == before["WatchedSource c"], "a source not attempted was written")
        let stored = try titles(c)
        #expect(stored.filter { $0.contains("Recital a") }.count == 2 && !stored.contains { $0.contains("Recital c") },
                Comment(rawValue: "\(stored)"))
        #expect(outcome.warning?.contains(ScoutWarningCopy.notAttempted(1)) == true, Comment(rawValue:
            outcome.warning ?? "nil"))

        // Dan's next save, of his own edit, goes through.
        let feedback = ActionFeedback()
        let a = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first { $0.groupName.contains("Recital a") })
        a.fitReason = "Dan's own note"
        #expect(ctx.saveOrWarn(org: a.groupName, feedback: feedback), "Dan's next save failed after the landing")
        #expect(feedback.message == nil)
    }

    // MARK: - The entry flush keeps an edit made before the landing

    // A show the failing source re-lists, with an edit Dan made before the landing and had not saved. The
    // revert restores COMMITTED values, so without the entry flush it would put the edit back too.
    @Test func aPendingEditOnARowTheFailedSourceTouchesSurvives() async throws {
        let c = try container()
        let ctx = c.mainContext
        html("b", in: ctx)
        try ctx.save()
        _ = await ingest(results([result("b")]), into: ctx)
        let show = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first { $0.groupName == "Recital b 0" })
        let source = try #require(try ctx.fetch(FetchDescriptor<WatchedSource>()).first)
        source.pendingContentHash = "newer-b"
        source.hasUnreadChanges = true
        try ctx.save()
        show.fitReason = "Dan's pending edit"
        show.missedScoutCount += 1
        #expect(ctx.hasChanges, "the edit was saved before the landing, so nothing below tests the entry flush")
        let failing = FailOne("b")

        let outcome = await ingest(results([result("b")]), into: ctx, saveSource: failing.save,
                                   classify: { _ in .source })

        #expect(failing.changedAtRefusal.contains("Recital b 0"), Comment(rawValue:
            "the failed source did not touch the edited show, so its survival proves nothing: \(failing.changedAtRefusal)"))
        #expect(states(outcome)["b"] == .saveFailed)
        let committed = try #require(try ModelContext(c).fetch(FetchDescriptor<Prospect>()).first { $0.groupName == "Recital b 0" })
        #expect(committed.fitReason == "Dan's pending edit", "a pending edit made before the landing was put back")
        #expect(committed.missedScoutCount == 1, "a pending miss made before the landing was put back")
        #expect(show.fitReason == "Dan's pending edit")
    }

    // MARK: - A row the failed source inserted is gone, and the next source lands on a live row

    @Test func theNextSourceUpsertingTheSameShowLandsOnALiveRow() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["b", "c"] { html(id, in: ctx) }
        try ctx.save()
        let failing = FailOne("b")
        let shared = ["Shared Recital"]

        let outcome = await ingest(results([result("b", titles: shared), result("c", titles: shared)]), into: ctx,
                                   saveSource: failing.save, classify: { _ in .source })

        #expect(failing.pendingAtRefusal.inserted >= 1, "b never inserted the shared show, so c's landing proves nothing")
        let s = states(outcome)
        #expect(s["b"] == .saveFailed && s["c"] == .ingested(found: 1), Comment(rawValue: "\(s)"))
        let rows = try ModelContext(c).fetch(FetchDescriptor<Prospect>()).filter { $0.groupName == "Shared Recital" }
        #expect(rows.count == 1, Comment(rawValue: "\(rows.count) stored rows hold the show both sources listed"))
        #expect(rows.first?.sourceIds == ["c"], Comment(rawValue:
            "the stored row is not the later source's: \(rows.first?.sourceIds ?? [])"))
    }

    // MARK: - Not reverted: the landing stops, by name

    // A committed row the failed turn deleted cannot be brought back without `rollback()`, which is banned.
    // Nothing on the landing path deletes one, so the deletion is the injected save's own.
    @Test func aFailedSourceThatCannotBePutBackStopsTheLandingByName() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b", "c"] { html(id, in: ctx) }
        try ctx.save()
        _ = await ingest(results([result("a")]), into: ctx)
        for id in ["a", "b", "c"] {
            let s = try #require(try ctx.fetch(FetchDescriptor<WatchedSource>()).first { $0.sourceId == id })
            s.pendingContentHash = "again-\(id)"
            s.hasUnreadChanges = true
        }
        try ctx.save()
        let failing = FailOne("b")
        failing.beforeThrowing = { ctx in
            if let committed = try? ctx.fetch(FetchDescriptor<Prospect>()).first(where: { $0.groupName == "Recital a 1" }) {
                ctx.delete(committed)
            }
        }

        let outcome = await ingest(results([result("b"), result("c")]), into: ctx, saveSource: failing.save,
                                   classify: { _ in .source })

        guard case .notReverted(let source, let why)? = outcome.landingStop else {
            Issue.record(Comment(rawValue: "the landing was not stopped as not reverted: \(String(describing: outcome.landingStop))"))
            return
        }
        #expect(source == "Org b")
        #expect(why.contains { $0.contains("deleted") }, Comment(rawValue: "\(why)"))
        #expect(states(outcome)["c"] == .notAttempted, "a source after a failure that was not put back was landed")
        // No further save was made, so the delete the revert could not undo never reached the store.
        let stored = try titles(c)
        #expect(stored.contains("Recital a 1"), Comment(rawValue:
            "a landing stopped as not reverted saved what it could not restore: \(stored)"))
        #expect(outcome.warning?.contains(ScoutWarningCopy.notReverted("Org b")) == true, Comment(rawValue:
            outcome.warning ?? "nil"))
    }

    // MARK: - The entry flush refuses the landing by name when it cannot save

    @Test func anEntryFlushThatCannotSaveRefusesTheLandingAndLeavesTheEditPending() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b"] { html(id, in: ctx) }
        try ctx.save()
        _ = await ingest(results([result("a")]), into: ctx)
        let show = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first { $0.groupName == "Recital a 0" })
        for s in try ctx.fetch(FetchDescriptor<WatchedSource>()) {
            s.pendingContentHash = "again-\(s.sourceId)"
            s.hasUnreadChanges = true
        }
        try ctx.save()
        show.fitReason = "Dan's unsaved edit"
        var sourceSaves = 0

        let outcome = await ingest(results([result("b")]), into: ctx,
                                   saveSource: { _ in sourceSaves += 1 },
                                   saveEntry: { _ in throw SaveRefused() })

        #expect(outcome.landingStop == .recentEditsUnsaved(rows: ["Recital a 0"]), Comment(rawValue:
            "\(String(describing: outcome.landingStop))"))
        #expect(sourceSaves == 0, "a source was applied after the entry flush failed")
        #expect(!outcome.sources.contains { $0.state == .ingested(found: 2) })
        #expect(try ModelContext(c).fetch(FetchDescriptor<Prospect>()).allSatisfy { !$0.groupName.contains("Recital b") })
        #expect(show.fitReason == "Dan's unsaved edit" && ctx.hasChanges, "the pending edit did not stay pending")
        #expect(ctx.changedModelsArray.count == 1, Comment(rawValue:
            "the refused landing left \(ctx.changedModelsArray.count) rows pending, not just Dan's edit"))
        #expect(outcome.warning?.contains(ScoutWarningCopy.recentEditsUnsaved(["Recital a 0"])) == true,
                Comment(rawValue: outcome.warning ?? "nil"))
    }

    // L371, L665: the refused landing's results are kept by content hash, and land once the edits are saved.
    @Test func aRefusedLandingKeepsItsResultsAndTheyLandOnceTheEditsAreSaved() async throws {
        let c = try container()
        let ctx = c.mainContext
        html("b", in: ctx)
        let edited = WatchedSource(sourceId: "edited", orgName: "Org edited", listingsURL: "https://e.example/", kind: .html)
        ctx.insert(edited)
        try ctx.save()
        edited.notes = "Dan's unsaved note"
        let pending = PendingScoutIngests(directory: try sandboxes.make(named: "refused-entry-flush"))
        let r = results([result("b")])
        let flight = LandingSingleFlight(sleep: { _ in })

        let refused = await ScoutExtractLanding.land(try JSONEncoder().encode(r), r, clients: [], history: [],
                                                     blocked: .empty, today: ScoutTestClock.beforeAllFixtures,
                                                     now: now, landings: flight, pending: pending,
                                                     saveEntry: { _ in throw SaveRefused() }, into: ctx)
        #expect(refused.outcome.landingStop == .recentEditsUnsaved(rows: ["Org edited"]), Comment(rawValue:
            "\(String(describing: refused.outcome.landingStop))"))
        #expect(try pending.list().count == 1, "the refused landing's results were not kept")

        try ctx.save()   // Dan's edit saves after all
        let offered = await ScoutExtractLanding.offerPending(clients: [], history: [], blocked: .empty, now: now,
                                                            landings: flight, pending: pending, into: ctx)
        #expect(offered.landed.count == 1, "the kept results did not land once the edits were saved")
        #expect(try titles(c).filter { $0.contains("Recital b") }.count == 2)
        #expect(try pending.list().isEmpty)
    }

    // MARK: - A failed closing save is put back, so a retry moves the miss once

    private func ownedShow(_ ctx: ModelContext, owner: String) -> Prospect {
        let p = Prospect(naturalKey: "gone-show", groupName: "Wrenfield Players", discipline: "theatre",
                         venue: "Callowmere Hall", performanceDate: "2099-09-19",
                         sourceListingURL: "https://\(owner).example/wrenfield",
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        p.sourceIds = [owner]
        ctx.insert(p)
        return p
    }

    @Test func aFailedClosingSaveIsPutBackAndARetryMovesTheMissOnce() async throws {
        let c = try container()
        let ctx = c.mainContext
        let s = html("kaufman", in: ctx)
        s.successfulCheckCount = WatchedSource.warmupRuns
        s.baselineFeedCount = 2
        let show = ownedShow(ctx, owner: "kaufman")
        try ctx.save()
        let r = results([result("kaufman")])
        let journals = LandingJournals(directory: try sandboxes.make(named: "closing-retry"),
                                       readFailures: HandoffReadFailures())

        let failed = await ingest(r, into: ctx, sequence: 5, saveClosing: { _ in throw SaveRefused() },
                                  journals: journals)

        #expect(failed.saveFailed)
        #expect(try Self.holdsOnlyWhatTheStoreHolds(ctx, c),
                "a failed closing save left writes the store does not hold for the retry to land again")
        #expect(show.missedScoutCount == 0, "the miss rode a closing save that failed")
        // #4335 (A6): the source's check and its page hash now ride the SAME save as its shows, which went
        // through, so they are in the store; only the closing save's reconcile was put back. Before #4335 they
        // rode the closing save and were put back with it.
        #expect(s.successfulCheckCount == WatchedSource.warmupRuns + 1 && s.lastContentHash == "new-kaufman")

        let retried = await ingest(r, into: ctx, sequence: 5, journals: journals)
        #expect(!retried.saveFailed)
        let fresh = ModelContext(c)
        #expect(try fresh.fetch(FetchDescriptor<Prospect>()).first { $0.naturalKey == "gone-show" }?.missedScoutCount == 1,
                "the retried landing did not record exactly one miss")
        #expect(try fresh.fetch(FetchDescriptor<WatchedSource>()).first?.successfulCheckCount == WatchedSource.warmupRuns + 1,
                "the retried landing did not count exactly one more check")
    }

    // #4338 (A10): a failed save says "will try again" only when the recovery really will: the landing kept its
    // journal and its record has attempts left. With no journal, nothing will retry it, and it says to run again.
    @Test func aFailedSaveSaysItWillBeRetriedOnlyWhenItsJournalIsKept() async throws {
        let c = try container()
        let ctx = c.mainContext
        html("kept", in: ctx)
        html("bare", in: ctx)
        try ctx.save()
        let journals = LandingJournals(directory: try sandboxes.make(named: "retried-by-recovery"),
                                       readFailures: HandoffReadFailures())

        let kept = await ingest(results([result("kept")]), into: ctx, saveClosing: { _ in throw SaveRefused() },
                                journals: journals)
        #expect(kept.saveFailed && kept.retriedByRecovery)
        #expect(kept.warning?.hasPrefix(ScoutWarningCopy.saveFailedRetried) == true, Comment(rawValue: kept.warning ?? "nil"))
        #expect(try journals.list().count == 1, "the landing said it would be retried and kept no journal to retry")

        let bare = await ingest(results([result("bare")]), into: ctx, saveClosing: { _ in throw SaveRefused() })
        #expect(bare.saveFailed && !bare.retriedByRecovery)
        #expect(bare.warning?.hasPrefix(ScoutWarningCopy.saveFailed) == true)

        let landed = await ingest(results([result("kept")]), into: ctx, journals: journals)
        #expect(!landed.saveFailed && !landed.retriedByRecovery)
    }

    // MARK: - #4422's note: offered again, a landing whose save failed applies its writes once

    @Test func aLandingWhoseSavesFailedOfferedAgainAppliesItsCapturedWritesOnce() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["f", "b"] { html(id, in: ctx) }
        try ctx.save()
        let r = results([ScoutExtractResult(sourceId: "f", verdict: .unreadable, events: [], note: "could not read it"),
                         result("b")])
        let failing = FailOne("b")

        let first = await ingest(r, into: ctx, sequence: 7, saveSource: failing.save,
                                 saveClosing: { _ in throw SaveRefused() })
        #expect(first.saveFailed)
        #expect(try Self.holdsOnlyWhatTheStoreHolds(ctx, c),
                "the failed landing left writes the store does not hold for the re-offer to apply again")

        let again = await ingest(r, into: ctx, sequence: 7)
        #expect(!again.saveFailed)
        let f = try #require(try ModelContext(c).fetch(FetchDescriptor<WatchedSource>()).first { $0.sourceId == "f" })
        #expect(f.failedReadStreak == 1, Comment(rawValue:
            "one failed read was counted \(f.failedReadStreak) times across a failed landing and its re-offer"))
    }

    // MARK: - runScout's native path honours a failed save (the #499 rule)

    private static let ovationTix = """
        [{"date":"%@","productions":[{"productionId":1,"name":"Bone Wars"}]}]
        """

    private func inlinePage(_ url: URL, hash: String) -> FetchedPage {
        let json = Data(String(format: Self.ovationTix, night(1)).utf8)
        return FetchedPage(normalizedHTML: "<p/>", finalURL: "https://web.ovationtix.com/trs/cal/277",
                           contentHash: hash, followedTicketLinkFrom: url.absoluteString,
                           ticketingFeedURL: "https://web.ovationtix.com/trs/cal/277", ticketingFeedJSON: json)
    }

    private func runInline(_ ctx: ModelContext, saveSource: @escaping (ModelContext) throws -> Void,
                           classify: @escaping (Error) -> LandingSaveFailure.Scope = LandingSaveFailure.classify,
                           movementLog: any FeedMovementLog.Sink = FeedMovementLog.file,
                           journals: LandingJournals? = nil)
        async throws -> ScoutService.Outcome {
        try await ScoutService.runScout(
            into: ctx, depth: .readChanged,
            fetch: { url, _, _ in self.inlinePage(url, hash: "inline-new-\(url.host ?? "")") },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            now: now, defaults: ScratchDefaults.make("ScoutFailedSaveIsolationTests"),
            landings: LandingSingleFlight(sleep: { _ in }), sequenceFloor: { 0 },
            saveSource: saveSource, classifySaveFailure: classify, journals: journals, movementLog: movementLog,
            exportURL: AbsentHandoff.export, importedHistory: AbsentHandoff.history)
    }

    private final class Lines: FeedMovementLog.Sink {
        private(set) var lines: [String] = []
        func append(_ line: String) { lines.append(line) }
        func count(_ sourceId: String) -> Int { lines.filter { $0.contains("source=\(sourceId) ") }.count }
    }

    @Test func aNativeSourceWhoseSaveFailsIsNeverMarkedRead() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["inline-a", "inline-b"] { html(id, in: ctx) }
        try ctx.save()
        let failing = FailOne("inline-a")
        let lines = Lines()

        let outcome = try await runInline(ctx, saveSource: failing.save, classify: { _ in .source }, movementLog: lines)

        #expect(failing.refused == 1, "the native source's save was never refused, so nothing here failed")
        let s = states(outcome)
        #expect(s["inline-a"] == .saveFailed, Comment(rawValue: "\(s)"))
        #expect(s["inline-b"].map { if case .ingested = $0 { return true }; return false } == true,
                Comment(rawValue: "the source after the failure did not land: \(s)"))
        try ctx.save()
        let a = try #require(try ModelContext(c).fetch(FetchDescriptor<WatchedSource>()).first { $0.sourceId == "inline-a" })
        #expect(a.lastContentHash == "old", Comment(rawValue:
            "a native source whose save failed was marked read: \(a.lastContentHash ?? "nil")"))
        #expect(a.hasUnreadChanges, "a native source whose save failed had its unread flag cleared")
        let b = try #require(try ModelContext(c).fetch(FetchDescriptor<WatchedSource>()).first { $0.sourceId == "inline-b" })
        #expect(b.lastContentHash == "inline-new-inline-b.example")
        // #4335 (RC6): a movement line only for the source whose save went through, appended once.
        #expect(lines.count("inline-a") == 0 && lines.count("inline-b") == 1, Comment(rawValue: "\(lines.lines)"))
    }

    // #4338 (the review of 29db676): a source level failure lets the landing carry on, and its closing save can then go
    // through. The journal is kept for the recovery all the same, so the summary must say it will be retried: the
    // flag was set only where a save failed, never from the outcome a merged source failure left behind.
    @Test func aSourceLevelFailureTheLandingCarriedOnFromSaysItWillBeRetried() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["inline-a", "inline-b"] { html(id, in: ctx) }
        try ctx.save()
        let journals = LandingJournals(directory: try sandboxes.make(named: "source-level-retried"),
                                       readFailures: HandoffReadFailures())

        let outcome = try await runInline(ctx, saveSource: FailOne("inline-a").save, classify: { _ in .source },
                                          journals: journals)

        #expect(outcome.saveFailed && outcome.landingStop == nil, Comment(rawValue: "\(states(outcome))"))
        #expect(try journals.list().count == 1, "the landing kept no journal, so nothing would retry it")
        #expect(outcome.retriedByRecovery, "the landing kept its journal for the recovery and said to run the scout again")
    }

    @Test func aStoreLevelFailureOnTheNativePathStopsTheSweepsLanding() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["inline-a", "inline-b"] { html(id, in: ctx) }
        try ctx.save()
        let failing = FailOne("inline-a")

        let outcome = try await runInline(ctx, saveSource: failing.save)

        let s = states(outcome)
        #expect(s["inline-a"] == .saveFailed && s["inline-b"] == .notAttempted, Comment(rawValue: "\(s)"))
        #expect(outcome.landingStop == .storeRefusedASave(source: "Org inline-a"))
        #expect(!ctx.hasChanges, "the stopped sweep left writes pending")
        let b = try #require(try ModelContext(c).fetch(FetchDescriptor<WatchedSource>()).first { $0.sourceId == "inline-b" })
        #expect(b.lastContentHash == "old" && b.lastTouchedSequence == 0, "a source after the stop was landed")
    }
}
