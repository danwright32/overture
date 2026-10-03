import Testing
import Foundation
import SwiftData

// #4335 (A6, the recovery): an interrupted scout landing is finished automatically, at idle, from its journal
// and (for an ingest) its kept copy, counting nothing twice; a stale one is retired rather than replayed; and a
// recovery that keeps failing stops after `LandingRecovery.attemptCap` attempts, saying so.
//
// "Interrupted" is produced the way `ScoutResultsKeptAndReplayedTests` produces it: the second source's save
// refused at store level and the closing save refused too, which leaves the store as a crash at that point
// would (the first source saved, nothing after it) and the journal and the kept copy on disk. Every name is
// invented (L155).
@MainActor
@Suite("An interrupted scout landing is finished at idle, once, or retired (#4335)")
final class LandingRecoveryTests {
    private let sandboxes = TemporarySandboxes()
    private let started = Date(timeIntervalSince1970: 1_790_000_000.25)
    private let later = Date(timeIntervalSince1970: 1_790_090_000)
    private struct SaveRefused: Error {}

    private final class Lines: FeedMovementLog.Sink {
        private(set) var lines: [String] = []
        func append(_ line: String) { lines.append(line) }
    }

    private func container() throws -> ModelContainer {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        c.mainContext.autosaveEnabled = false
        return c
    }

    private func night(_ n: Int) -> String {
        EasternDate.dayString(from: Calendar(identifier: .gregorian).date(byAdding: .day, value: 30 + n, to: started)!)
    }

    @discardableResult
    private func html(_ id: String, in ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: "Org \(id)", listingsURL: "https://\(id).example/events",
                              kind: .html)
        s.venueLocation = "New York, NY"
        s.lastContentHash = "old-\(id)"
        s.pendingContentHash = "new-\(id)"
        s.hasUnreadChanges = true
        ctx.insert(s)
        return s
    }

    private func data(_ ids: [String]) throws -> Data {
        try JSONEncoder().encode(ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z", results: ids.map { id in
            ScoutExtractResult(sourceId: id, verdict: .upcomingListings,
                               events: (0..<2).map { k in
                                   ScoutExtractEvent(title: "Recital \(id) \(k)", presenter: "Recital \(id) \(k)",
                                                     venue: "Merkin Hall", performanceDate: night(k),
                                                     sourceUrl: "https://\(id).example/r\(k)")
                               },
                               note: "read \(id)")
        }))
    }

    private struct Folders {
        let pending: PendingScoutIngests
        let journals: LandingJournals
    }

    private func folders(_ name: String) throws -> Folders {
        let root = try sandboxes.make(named: name)
        return Folders(pending: PendingScoutIngests(directory: root.appendingPathComponent("pending"),
                                                    readFailures: HandoffReadFailures()),
                       journals: LandingJournals(directory: root.appendingPathComponent("journals"),
                                                 readFailures: HandoffReadFailures()))
    }

    // A save that refuses, as a store would, the first time it carries the named source's row.
    private final class FailOne {
        let sourceId: String
        private(set) var refused = 0
        init(_ sourceId: String) { self.sourceId = sourceId }
        func save(_ ctx: ModelContext) throws {
            if refused == 0, ctx.changedModelsArray.contains(where: { ($0 as? WatchedSource)?.sourceId == sourceId }) {
                refused += 1
                throw SaveRefused()
            }
            try ctx.save()
        }
    }

    // An ingest of `ids` interrupted after the first: the first landed, the rest not, journal and copy kept.
    // Answers the run identity (the bytes' content hash), encoded once, because two encodings of one value need
    // not be the same bytes.
    @discardableResult
    private func interruptedIngest(_ ids: [String], into ctx: ModelContext, _ f: Folders) async throws -> String {
        let bytes = try data(ids)
        _ = await ScoutExtractLanding.land(bytes, try ScoutExtractResultsDecoder.decode(bytes),
                                           clients: [], history: [], blocked: .empty,
                                           today: QueueModel.easternToday(started), now: started,
                                           landings: LandingSingleFlight(sleep: { _ in }), pending: f.pending,
                                           saveClosing: { _ in throw SaveRefused() }, journals: f.journals,
                                           saveSource: FailOne(ids[1]).save, movementLog: Lines(), into: ctx)
        return PendingScoutIngests.contentHash(of: bytes)
    }

    private func recover(_ ctx: ModelContext, _ f: Folders, at now: Date? = nil, sweep: () -> Void = {},
                         saveAttempt: (ModelContext) throws -> Void = { try $0.save() },
                         landings: LandingSingleFlight = LandingSingleFlight(sleep: { _ in }),
                         replaying: (String?) -> Void = { _ in })
        async -> LandingRecovery.Recovered? {
        await LandingRecovery.recoverNext(journals: f.journals, pending: f.pending, clients: [], history: [],
                                          blocked: .empty, landings: landings, now: now ?? later,
                                          sweep: sweep, saveAttempt: saveAttempt, movementLog: Lines(),
                                          replaying: replaying, into: ctx)
    }

    private func sources(_ c: ModelContainer) throws -> [String: WatchedSource] {
        Dictionary(uniqueKeysWithValues: try ModelContext(c).fetch(FetchDescriptor<WatchedSource>()).map { ($0.sourceId, $0) })
    }

    private func titles(_ c: ModelContainer) throws -> [String] {
        try ModelContext(c).fetch(FetchDescriptor<Prospect>()).map(\.groupName).filter { $0.hasPrefix("Recital") }.sorted()
    }

    private func survey(_ c: ModelContainer, _ f: Folders) throws -> [LandingRecovery.Finding] {
        try LandingRecovery.survey(journals: f.journals, pending: f.pending, in: ModelContext(c)).map(\.finding)
    }

    // MARK: - finishing an interrupted ingest

    // The plan's tests, together: the interrupted landing is finished by the recovery from its own copy, the
    // sources it had not landed land (L406: they are in the store, not merely reported), every source's check
    // moves exactly once, the journal and the copy are retired, and the record says when it was recovered.
    // The re-landed source is stamped with the landing's ORIGINAL now, because its content was read then.
    @Test func anInterruptedIngestIsFinishedFromItsCopyCountingEverySourceOnce() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b", "c"] { html(id, in: ctx) }
        try ctx.save()
        let f = try folders("recover-ingest")
        let identity = try await interruptedIngest(["a", "b", "c"], into: ctx, f)
        #expect(try titles(c) == ["Recital a 0", "Recital a 1"])
        #expect(try survey(c, f) == [.replay])

        var replaying: [String?] = []
        let recovered = await recover(ctx, f, replaying: { replaying.append($0) })
        #expect(recovered == .landed(startedAt: started, sources: 2), Comment(rawValue: String(describing: recovered)))
        // L459: the stall watchdog is told the replay's run as it starts and that it ended.
        #expect(replaying == [identity, nil])
        #expect(try titles(c).count == 6)
        let stored = try sources(c)
        for id in ["a", "b", "c"] {
            #expect(stored[id]?.successfulCheckCount == 1, Comment(rawValue:
                "\(id) counted \(stored[id]?.successfulCheckCount ?? -1) checks"))
            #expect(stored[id]?.lastCheckedAt == started, "\(id) was stamped with the recovery's clock")
        }
        #expect(try f.journals.list().isEmpty && f.pending.list().isEmpty)
        let run = try #require(try ModelContext(c).fetch(FetchDescriptor<LandingRun>()).first)
        #expect(run.landedAt == started && run.recoveredAt == later && run.attemptCount == 1)
    }

    // Recovery run twice is a no-op the second time: nothing pending, nothing changed.
    @Test func aSecondRecoveryFindsNothingAndChangesNothing() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b"] { html(id, in: ctx) }
        try ctx.save()
        let f = try folders("recover-twice")
        try await interruptedIngest(["a", "b"], into: ctx, f)
        _ = await recover(ctx, f)
        let after = try LandingOracle.snapshot(of: c)

        #expect(await recover(ctx, f) == nil)
        let differences = LandingOracle.differences(expected: LandingOracle.recording(of: after),
                                                    actual: try LandingOracle.snapshot(of: c), arm: .synthetic)
        #expect(differences.isEmpty, Comment(rawValue: differences.joined(separator: "\n")))
    }

    // MARK: - stale journals are retired, never replayed (L23)

    // A source a later run checked and FAILED after the interrupted one read it is not replayed: the later
    // failure, its streak and its check time survive, and with every source overtaken the journal and its
    // copy are retired as superseded.
    @Test func aJournalWhoseSourcesALaterRunTouchedIsRetiredNotReplayed() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b"] { html(id, in: ctx) }
        try ctx.save()
        let f = try folders("recover-stale")
        try await interruptedIngest(["a", "b"], into: ctx, f)
        let landedSequence = try sources(c)["a"]?.lastTouchedSequence ?? -1
        let journal = try #require(f.journals.pending(sequence: landedSequence))
        // A later run read both and failed on b.
        for s in try ctx.fetch(FetchDescriptor<WatchedSource>()) {
            s.lastTouchedSequence = journal.sequence + 1
            if s.sourceId == "b" { s.recordFailedRead(.verdict(.unreadable), now: later) }
        }
        try ctx.save()
        #expect(try survey(c, f) == [.superseded(bySequence: journal.sequence + 1)])

        let recovered = await recover(ctx, f)
        #expect(recovered == .retired(startedAt: started, finding: .superseded(bySequence: journal.sequence + 1)))
        let b = try #require(try sources(c)["b"])
        #expect(b.failedReadStreak == 1 && b.lastCheckedAt == later && b.successfulCheckCount == 0,
                "the later run's failure on b was overwritten by a stale journal")
        #expect(try titles(c) == ["Recital a 0", "Recital a 1"], "a stale journal's results were landed")
        #expect(try f.journals.list().isEmpty && f.pending.list().isEmpty)
    }

    // An ingest journal whose record says it landed (its removal failed) is retired, and its copy with it.
    @Test func aJournalWhoseLandingFinishedIsRetired() async throws {
        let c = try container()
        let ctx = c.mainContext
        html("a", in: ctx)
        let f = try folders("recover-finished")
        let bytes = try data(["a"])
        let hash = PendingScoutIngests.contentHash(of: bytes)
        try f.pending.record(bytes, sequence: 4, now: started)
        try f.journals.start(LandingJournal(runIdentity: hash, sequence: 4, entryPoint: .scoutExtractIngest,
                                            sources: [.init(sourceId: "a", pageHash: "new-a")], now: started,
                                            resultsCopy: hash))
        ctx.insert(LandingRun(runIdentity: hash, landedAt: started, sequence: 4, entryPoint: .scoutExtractIngest,
                              startedAt: started))
        try ctx.save()
        #expect(try survey(c, f) == [.finished])

        #expect(await recover(ctx, f) == .retired(startedAt: started, finding: .finished))
        #expect(try f.journals.list().isEmpty && f.pending.list().isEmpty)
        #expect(LandingWaitCopy.recovered(.retired(startedAt: started, finding: .finished)) == nil)
    }

    // MARK: - an ingest whose copy is not there is refused by name (L420)

    @Test func anIngestJournalWhoseCopyIsMissingIsRefusedByName() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b"] { html(id, in: ctx) }
        try ctx.save()
        let f = try folders("recover-no-copy")
        try await interruptedIngest(["a", "b"], into: ctx, f)
        for case .entry(let entry) in try f.pending.list() { try f.pending.remove(entry.contentHash) }
        guard case .copyMissing(let why)? = try survey(c, f).first else {
            Issue.record(Comment(rawValue: "a journal with no copy was judged \(try survey(c, f))"))
            return
        }
        #expect(why.contains("could not be read"))
        let recovered = await recover(ctx, f)
        guard case .notFinished(_, let said)? = recovered else {
            Issue.record(Comment(rawValue: "a journal with no copy was \(String(describing: recovered))"))
            return
        }
        #expect(said == why)
        #expect(try titles(c) == ["Recital a 0", "Recital a 1"], "something was landed without the copy")
        #expect(try f.journals.list().count == 1, "the journal was retired although nothing finished it")
    }

    // MARK: - attempts are counted before they are made, and capped

    // An attempt whose own count cannot be saved is not made.
    @Test func anAttemptThatCannotBeRecordedIsNotMade() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b"] { html(id, in: ctx) }
        try ctx.save()
        let f = try folders("recover-unrecorded")
        try await interruptedIngest(["a", "b"], into: ctx, f)

        let recovered = await recover(ctx, f, saveAttempt: { _ in throw SaveRefused() })
        guard case .notFinished(_, let why)? = recovered else {
            Issue.record(Comment(rawValue: "an unrecorded attempt was \(String(describing: recovered))"))
            return
        }
        #expect(why.contains("could not be recorded"))
        #expect(try titles(c) == ["Recital a 0", "Recital a 1"], "an attempt nothing recorded landed anyway")
        // And the count it raised is put back, so no later save carries a half recorded attempt.
        try ctx.save()
        #expect(try ModelContext(c).fetch(FetchDescriptor<LandingRun>()).map(\.attemptCount) == [0],
                "an attempt that could not be recorded was carried to the store by a later save")
    }

    // An attempt whose record did not exist yet (the landing never reached its first save) is put back as an
    // insert, so nothing is left for a later save to carry either.
    @Test func anUnrecordedFirstAttemptLeavesNoRecordBehind() async throws {
        let c = try container()
        let ctx = c.mainContext
        html("a", in: ctx)
        try ctx.save()
        let f = try folders("recover-unrecorded-first")
        try f.journals.start(LandingJournal(runIdentity: "sweep-first", sequence: 5, entryPoint: .runScoutLanding,
                                            sources: [.init(sourceId: "a", pageHash: nil)], now: started))

        _ = await recover(ctx, f, saveAttempt: { _ in throw SaveRefused() })
        try ctx.save()
        #expect(try ModelContext(c).fetch(FetchDescriptor<LandingRun>()).isEmpty,
                "the record of an attempt that could not be recorded reached the store")
    }

    // L5: an ingest whose sources were switched off since keeps its results, and its replay (not the recovery)
    // decides what lands. Its copy is removed only once that landing has finished.
    @Test func anIngestWhoseSourcesWereSwitchedOffIsStillReplayedNotDiscarded() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b"] { html(id, in: ctx) }
        try ctx.save()
        let f = try folders("recover-switched-off")
        try await interruptedIngest(["a", "b"], into: ctx, f)
        // Every source it named, so no watched row is left to hold the journal open.
        for s in try ctx.fetch(FetchDescriptor<WatchedSource>()) { WatchlistEditing.stopWatching(s, in: ctx) }

        #expect(try survey(c, f) == [.replay], "switched off sources' results were judged nothing to land")
        #expect(try f.pending.list().count == 1)
        guard case .landed? = await recover(ctx, f) else {
            Issue.record("the replay did not finish")
            return
        }
        #expect(try titles(c).count == 4)
        #expect(try f.pending.list().isEmpty && f.journals.list().isEmpty)
    }

    // A landing whose recovery keeps failing is tried `attemptCap` times, each counted, and then stops, saying so
    // with the calendars it had not saved, and never again says it will try again.
    @Test func aRecoveryThatKeepsFailingStopsAfterTheCap() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b"] { html(id, in: ctx) }
        try ctx.save()
        let f = try folders("recover-cap")
        try await interruptedIngest(["a", "b"], into: ctx, f)
        // The store refuses every save of b's row from now on.
        let refusing = { (context: ModelContext) throws in
            if context.changedModelsArray.contains(where: { ($0 as? WatchedSource)?.sourceId == "b" }) {
                throw SaveRefused()
            }
            try context.save()
        }
        var said: [LandingRecovery.Recovered?] = []
        for _ in 0..<LandingRecovery.attemptCap + 1 {
            said.append(await LandingRecovery.recoverNext(
                journals: f.journals, pending: f.pending, clients: [], history: [], blocked: .empty,
                landings: LandingSingleFlight(sleep: { _ in }), now: later, sweep: {},
                saveSource: refusing, movementLog: Lines(), into: ctx))
        }
        let run = try #require(try ModelContext(c).fetch(FetchDescriptor<LandingRun>()).first)
        #expect(run.attemptCount == LandingRecovery.attemptCap, Comment(rawValue: "attempted \(run.attemptCount) times"))
        guard case .notFinished? = said[0], case .stoppedRetrying(_, let attempts, let unlanded)? = said.last else {
            Issue.record(Comment(rawValue: "the recovery said \(said)"))
            return
        }
        #expect(attempts == LandingRecovery.attemptCap && unlanded == 1)
        let line = try #require(LandingWaitCopy.recovered(said.last!!))
        #expect(!line.contains("try again"), Comment(rawValue: "a stopped recovery promised another try: \(line)"))
        #expect(line.contains("The calendar it had not saved stays unread"))
        #expect(try survey(c, f) == [.stoppedRetrying(attempts: LandingRecovery.attemptCap)])
    }

    // MARK: - runScout landings are re-read by the watch-only sweep

    @Test func anInterruptedSweepAsksForTheWatchOnlySweepAndIsRetiredOnceItRan() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b"] { html(id, in: ctx) }
        try ctx.save()
        let f = try folders("recover-sweep")
        try f.journals.start(LandingJournal(runIdentity: "sweep-x", sequence: 9, entryPoint: .runScoutLanding,
                                            sources: [.init(sourceId: "a", pageHash: nil),
                                                      .init(sourceId: "b", pageHash: nil)], now: started))
        #expect(try survey(c, f) == [.sweep])

        var swept = 0
        #expect(await recover(ctx, f, sweep: { swept += 1 }) == .sweepRequested(startedAt: started))
        #expect(swept == 1)
        // The sweep ran: every source now carries its higher sequence.
        for s in try ctx.fetch(FetchDescriptor<WatchedSource>()) { s.lastTouchedSequence = 10 }
        try ctx.save()
        #expect(await recover(ctx, f, sweep: { swept += 1 })
                == .retired(startedAt: started, finding: .superseded(bySequence: 10)))
        let left = try f.journals.list()
        #expect(swept == 1 && left.isEmpty)
    }

    // MARK: - one folder per landing (L433, L463)

    @Test func twoJournalFoldersNeverSeeEachOthersLandings() async throws {
        let c = try container()
        html("a", in: c.mainContext)
        try c.mainContext.save()
        let one = try folders("recover-one")
        let two = try folders("recover-two")
        try one.journals.start(LandingJournal(runIdentity: "sweep-one", sequence: 3, entryPoint: .runScoutLanding,
                                              sources: [.init(sourceId: "a", pageHash: nil)], now: started))
        #expect(try survey(c, one) == [.sweep])
        #expect(try survey(c, two).isEmpty)
    }

    // MARK: - what the journal costs, measured (opt in)

    // The plan asks for the journal's two writes (start, and retire at the end) to be measured. A journal holds
    // the run's source list, never the store, so its size is the watchlist's (39 sources in the frozen 4x
    // input) whatever the store's size. Opt in: TEST_RUNNER_MEASURE_4335=1.
    @Test func measureTheJournalsWrites() throws {
        guard ProcessInfo.processInfo.environment["MEASURE_4335"] != nil else {
            print("journal-cost: not measured. Set TEST_RUNNER_MEASURE_4335=1 to measure it.")
            return
        }
        let f = try folders("journal-cost")
        let sources = (0..<39).map { LandingJournal.Source(sourceId: "source-\($0)", pageHash: String(repeating: "a", count: 64),
                                                           checksBefore: 7, baselineBefore: 12) }
        var starts: [Double] = [], retires: [Double] = []
        for round in 0..<21 {
            let journal = LandingJournal(runIdentity: String(repeating: "b", count: 64), sequence: 1_000 + round,
                                         entryPoint: .scoutExtractIngest, sources: sources, now: started,
                                         resultsCopy: String(repeating: "b", count: 64))
            let t0 = ContinuousClock.now
            try f.journals.start(journal)
            let t1 = ContinuousClock.now
            f.journals.retire(journal)
            let t2 = ContinuousClock.now
            starts.append(Double((t1 - t0).components.attoseconds) / 1e15 + Double((t1 - t0).components.seconds) * 1000)
            retires.append(Double((t2 - t1).components.attoseconds) / 1e15 + Double((t2 - t1).components.seconds) * 1000)
        }
        func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        print(String(format: "journal-cost: 39 sources, 21 rounds: start (write, fsync, rename, fsync folder) median %.2f ms, max %.2f ms; retire (remove, fsync folder) median %.2f ms, max %.2f ms",
                     median(starts), starts.max() ?? 0, median(retires), retires.max() ?? 0))
        #expect(try f.journals.list().isEmpty)
    }

    // MARK: - only at idle (decision 5)

    @Test func theRecoveryRunsOnlyWhenNothingIsLandingNothingIsRunningAndTheMacIsUntouched() {
        #expect(RecoveryIdle.judge(landingHeld: false, scoutRunning: false, secondsSinceInput: 121)
                == .idle(inputQuietFor: 121))
        #expect(RecoveryIdle.judge(landingHeld: true, scoutRunning: false, secondsSinceInput: 900) == .landingInProgress)
        #expect(RecoveryIdle.judge(landingHeld: false, scoutRunning: true, secondsSinceInput: 900) == .scoutRunning)
        #expect(RecoveryIdle.judge(landingHeld: false, scoutRunning: false, secondsSinceInput: 119)
                == .inputRecent(secondsAgo: 119))
        // A reading the system did not give is never idle (L42).
        #expect(RecoveryIdle.judge(landingHeld: false, scoutRunning: false, secondsSinceInput: nil) == .inputUnmeasured)
        #expect(RecoveryIdle.judge(landingHeld: false, scoutRunning: false, secondsSinceInput: .nan) == .inputUnmeasured)
        // The real reading is a number on this Mac (measured 2026-10-03, see `RecoveryIdle.quietFor`).
        #expect(RecoveryIdle.secondsSinceInput().map { $0 >= 0 } == true)
    }

    // A Run press that has to wait behind the recovery says it is waiting for the interrupted landing (L703).
    @Test func aRunPressBehindTheRecoverySaysItWaitsForTheInterruptedLanding() async throws {
        // A deadline that does not pass while the test runs, so the press waits for the holder, not the clock.
        let flight = LandingSingleFlight(sleep: { _ in try? await Task.sleep(for: .seconds(3_600)) })
        let holder = try await flight.begin(entryPoint: .landingRecovery, priority: .scout, deadline: .seconds(60))
        var said: [String] = []
        let press = Task { @MainActor in
            try await flight.waitForTurnToStartARun(acknowledge: { said.append($0) })
        }
        await waitUntil("the press is waiting") { flight.queue == [.runPress] }
        holder.end()
        try await press.value
        #expect(said == [LandingWaitCopy.runPressWaitingForTheRecovery])
        #expect(LandingWaitCopy.runPressWaiting(behind: .scoutExtractIngest) == LandingWaitCopy.runPressWaiting)
    }

    // The launch sweep of kept copies leaves an interrupted landing's copy to the recovery, which finishes it at
    // idle, rather than finishing it at launch while Dan is at the Mac.
    @Test func theLaunchSweepLeavesAnInterruptedLandingToTheRecovery() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b"] { html(id, in: ctx) }
        try ctx.save()
        let f = try folders("recover-left")
        try await interruptedIngest(["a", "b"], into: ctx, f)

        let offered = await ScoutExtractLanding.offerPending(clients: [], history: [], blocked: .empty, now: later,
                                                            landings: LandingSingleFlight(sleep: { _ in }),
                                                            pending: f.pending, journals: f.journals, into: ctx)
        #expect(offered.isEmpty, Comment(rawValue: "the launch sweep acted on an interrupted landing: \(offered)"))
        #expect(try titles(c) == ["Recital a 0", "Recital a 1"])
        #expect(try survey(c, f) == [.replay])
    }
}
