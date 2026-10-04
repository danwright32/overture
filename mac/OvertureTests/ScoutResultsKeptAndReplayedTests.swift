import Testing
import Foundation
import SwiftData

// #4440: a fresh calendar ingest keeps a copy of its results BEFORE it applies anything, so a source save or a
// closing save that fails (or a crash) leaves them to be offered again rather than reported as failed over
// results nobody can land. Before this, only a landing that had to wait (A13) or that the entry flush refused
// (A5) kept one.
//
// #4335 (A6): and a kept copy offered again counts nothing twice. Each source's one save now carries its shows
// AND its bookkeeping (its check, its health, its page hash), so a source the earlier attempt landed carries
// this run's sequence and is recognised as landed: its bookkeeping is not applied again, its events are applied
// again only to rebuild its reconcile report (an upsert of the same events at the same `now` writes nothing
// new), and its feed movement line is appended once, after the save that carried it.
//
// HOW IT IS READ. Autosave is off. A failure is injected through the landing's save seams; "a crash between two
// sources' saves" is a store level refusal of the second source's save plus a refusal of the closing save, which
// leaves the store exactly as a crash at that point would: the first source saved, nothing after it. The store
// is read through a FRESH context. Every name is invented (L155).
@MainActor
@Suite("Fresh scout results are kept before they land, and land again counting nothing twice (#4440, #4335)")
final class ScoutResultsKeptAndReplayedTests {
    private let sandboxes = TemporarySandboxes()
    private let now = Date(timeIntervalSince1970: 1_790_000_000.25)
    private struct SaveRefused: Error {}

    private final class Lines: FeedMovementLog.Sink {
        private(set) var lines: [String] = []
        func append(_ line: String) { lines.append(line) }
        func count(_ sourceId: String) -> Int { lines.filter { $0.contains("source=\(sourceId) ") }.count }
    }

    private func container() throws -> ModelContainer {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        c.mainContext.autosaveEnabled = false
        return c
    }

    private var today: String { QueueModel.easternToday(now) }

    private func night(_ n: Int) -> String {
        EasternDate.dayString(from: Calendar(identifier: .gregorian).date(byAdding: .day, value: 30 + n, to: now)!)
    }

    // An html source past its warmup, with a page read and waiting to land, and one stored show only it lists,
    // which its results do NOT list, so its reconcile counts a miss on it.
    @discardableResult
    private func html(_ id: String, in ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: "Org \(id)", listingsURL: "https://\(id).example/events",
                              kind: .html, addedAt: now)
        s.venueLocation = "New York, NY"
        s.lastContentHash = "old-\(id)"
        s.pendingContentHash = "new-\(id)"
        s.hasUnreadChanges = true
        s.successfulCheckCount = WatchedSource.warmupRuns
        s.baselineFeedCount = 2
        ctx.insert(s)
        let gone = Prospect(naturalKey: "gone-\(id)", groupName: "Gone \(id)", discipline: "theatre",
                            venue: "Callowmere Hall", performanceDate: "2099-09-19",
                            sourceListingURL: "https://\(id).example/gone",
                            priorRelationship: "none", production: "self", profile: "strong",
                            coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                            matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        gone.sourceIds = [id]
        ctx.insert(gone)
        return s
    }

    private func result(_ id: String) -> ScoutExtractResult {
        ScoutExtractResult(sourceId: id, verdict: .upcomingListings,
                           events: (0..<2).map { k in
                               ScoutExtractEvent(title: "Recital \(id) \(k)", presenter: "Recital \(id) \(k)",
                                                 venue: "Merkin Hall", performanceDate: night(k),
                                                 sourceUrl: "https://\(id).example/r\(k)")
                           },
                           note: "read \(id)")
    }

    private func data(_ ids: [String]) throws -> Data {
        try JSONEncoder().encode(ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z",
                                                     results: ids.map(result)))
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

    private func land(_ data: Data, into ctx: ModelContext, _ f: Folders, lines: Lines,
                      saveSource: @escaping (ModelContext) throws -> Void = { try $0.save() },
                      saveClosing: @escaping (ModelContext) throws -> Void = { try $0.save() })
        async throws -> ScoutExtractLanding.Landed {
        await ScoutExtractLanding.land(data, try ScoutExtractResultsDecoder.decode(data), clients: [], history: [],
                                       blocked: .empty, today: today, now: now,
                                       landings: LandingSingleFlight(sleep: { _ in }), pending: f.pending,
                                       saveClosing: saveClosing, journals: f.journals, saveSource: saveSource,
                                       movementLog: lines, into: ctx)
    }

    private func offer(into ctx: ModelContext, _ f: Folders, lines: Lines) async -> ScoutExtractLanding.Offered {
        await ScoutExtractLanding.offerPending(clients: [], history: [], blocked: .empty, now: now.addingTimeInterval(60),
                                               landings: LandingSingleFlight(sleep: { _ in }), pending: f.pending,
                                               journals: f.journals, movementLog: lines, into: ctx)
    }

    // A save that refuses, as a store would, the first time it carries the named source's row.
    private final class FailOne {
        let sourceId: String
        private(set) var refused = 0
        var atRefusal: () -> Void = {}
        init(_ sourceId: String) { self.sourceId = sourceId }
        func save(_ ctx: ModelContext) throws {
            if refused == 0, ctx.changedModelsArray.contains(where: { ($0 as? WatchedSource)?.sourceId == sourceId }) {
                refused += 1
                atRefusal()
                throw SaveRefused()
            }
            try ctx.save()
        }
    }

    private func sources(_ c: ModelContainer) throws -> [String: WatchedSource] {
        Dictionary(uniqueKeysWithValues: try ModelContext(c).fetch(FetchDescriptor<WatchedSource>()).map { ($0.sourceId, $0) })
    }

    private func shows(_ c: ModelContainer) throws -> [String: Prospect] {
        Dictionary(uniqueKeysWithValues: try ModelContext(c).fetch(FetchDescriptor<Prospect>()).map { ($0.naturalKey, $0) })
    }

    private func titles(_ c: ModelContainer) throws -> [String] {
        try ModelContext(c).fetch(FetchDescriptor<Prospect>()).map(\.groupName).filter { $0.hasPrefix("Recital") }.sorted()
    }

    // MARK: - #4440: the copy is kept before anything is applied

    // The issue's own case. A landing that never had to wait holds a copy of its results, under this run's
    // sequence, before its first source's save; and the copy is gone once every save went through.
    @Test func aLandingThatNeverWaitedKeepsACopyBeforeItAppliesAnything() async throws {
        let c = try container()
        let ctx = c.mainContext
        html("a", in: ctx)
        try ctx.save()
        let f = try folders("kept-fresh")
        let bytes = try data(["a"])
        var atTheFirstSave: [PendingScoutIngests.Listed]?
        let landed = try await land(bytes, into: ctx, f, lines: Lines(), saveSource: { context in
            if atTheFirstSave == nil { atTheFirstSave = try? f.pending.list() }
            try context.save()
        })

        let entries = try #require(atTheFirstSave, "the first source never saved")
        guard case .entry(let entry)? = entries.first, entries.count == 1 else {
            Issue.record(Comment(rawValue: "no copy was kept when the first source saved: \(entries)"))
            return
        }
        #expect(entry.contentHash == PendingScoutIngests.contentHash(of: bytes))
        #expect(entry.sequence == (try sources(c)["a"]?.lastLandedSequence), "the copy was kept under another run's sequence")
        #expect(!landed.outcome.saveFailed && landed.outcome.landingStop == nil)
        #expect(try f.pending.list().isEmpty, "the copy outlived the landing whose saves all went through")
        #expect(try f.journals.list().isEmpty)
    }

    // L5, L665, and the failure path the issue names: a source's save refused at store level stops the landing
    // with that source put back. The results are KEPT, and offered again they land, so nothing was lost.
    @Test func aLandingWhoseSaveFailsKeepsItsResultsAndTheyLandWhenOfferedAgain() async throws {
        let c = try container()
        let ctx = c.mainContext
        html("a", in: ctx)
        try ctx.save()
        let f = try folders("kept-failed")
        let lines = Lines()
        let failing = FailOne("a")

        let first = try await land(try data(["a"]), into: ctx, f, lines: lines, saveSource: failing.save)
        #expect(failing.refused == 1)
        #expect(first.outcome.saveFailed)
        #expect(try titles(c).isEmpty)
        #expect(try f.pending.list().count == 1, "a landing whose save failed kept no copy of its results")
        #expect(lines.count("a") == 0, "a source whose save failed appended a movement line")

        let offered = await offer(into: ctx, f, lines: lines)
        #expect(offered.landed.count == 1, Comment(rawValue: "the kept results did not land: \(offered)"))
        #expect(try titles(c) == ["Recital a 0", "Recital a 1"])
        #expect(try sources(c)["a"]?.successfulCheckCount == WatchedSource.warmupRuns + 1)
        #expect(lines.count("a") == 1)
        #expect(try f.pending.list().isEmpty && f.journals.list().isEmpty)
    }

    // A kept copy whose record cannot be read is NOT an absent one (L215). Read as absent, a fresh sequence was
    // minted and a new copy written over it, so the sources an earlier attempt landed were counted again. Now
    // the landing is refused before anything is applied, and the unreadable record is left where it is.
    @Test func aKeptCopyWhoseRecordCannotBeReadRefusesTheLandingAndIsNotWrittenOver() async throws {
        let c = try container()
        let ctx = c.mainContext
        html("a", in: ctx)
        try ctx.save()
        let f = try folders("kept-unreadable-entry")
        let lines = Lines()
        let bytes = try data(["a"])
        _ = try await land(bytes, into: ctx, f, lines: lines, saveSource: FailOne("a").save)
        let hash = PendingScoutIngests.contentHash(of: bytes)
        let entry = f.pending.resultsURL(hash).deletingLastPathComponent().appendingPathComponent("entry.json")
        try Data("not an entry".utf8).write(to: entry)

        let again = try await land(bytes, into: ctx, f, lines: lines)
        guard case .resultsNotKept(let why)? = again.outcome.landingStop else {
            Issue.record(Comment(rawValue: "a kept copy with an unreadable record gave \(String(describing: again.outcome.landingStop))"))
            return
        }
        #expect(why.contains(entry.path), Comment(rawValue: why))
        #expect(try titles(c).isEmpty, "the landing applied results over a kept copy it could not read")
        #expect(try sources(c)["a"]?.successfulCheckCount == WatchedSource.warmupRuns)
        #expect(try Data(contentsOf: entry) == Data("not an entry".utf8), "the unreadable record was written over")
        // And the sweep's listing reports it by path rather than rewriting it as a run nobody knows.
        let listed = try f.pending.list()
        #expect(listed.contains { if case .unreadable(entry.path, _) = $0 { return true }; return false },
                Comment(rawValue: "listed \(listed)"))
        #expect(try Data(contentsOf: entry) == Data("not an entry".utf8), "listing the copies rewrote the record")
    }

    // A kept copy offered again lands with the `now` its landing started with (its stamps), but judges what is
    // still upcoming against the day it is offered on: a night that passed in between is not ingested as a
    // show still to come.
    @Test func aCopyOfferedAgainJudgesUpcomingByTheDayItIsOfferedOn() async throws {
        let c = try container()
        let ctx = c.mainContext
        html("b", in: ctx)
        try ctx.save()
        let f = try folders("kept-later-day")
        let lines = Lines()
        let first = try await land(try data(["b"]), into: ctx, f, lines: lines, saveSource: FailOne("b").save)
        #expect(first.outcome.saveFailed)

        // Offered a month later: night(0) has passed by then, night(1) is that very day.
        let later = Calendar(identifier: .gregorian).date(byAdding: .day, value: 31, to: now)!
        let offered = await ScoutExtractLanding.offerPending(
            clients: [], history: [], blocked: .empty, now: later, landings: LandingSingleFlight(sleep: { _ in }),
            pending: f.pending, journals: f.journals, movementLog: lines, into: ctx)
        #expect(offered.landed.count == 1, Comment(rawValue: "the kept results did not land: \(offered)"))
        #expect(try titles(c) == ["Recital b 1"], "a night that had passed by the day of the offer was ingested")
    }

    // L258: a copy that cannot be kept refuses the landing by name before anything is applied, as a journal
    // that cannot be written does, and says where the results still are.
    @Test func aCopyThatCannotBeKeptRefusesTheLandingBeforeAnythingIsApplied() async throws {
        let c = try container()
        let ctx = c.mainContext
        html("a", in: ctx)
        try ctx.save()
        let root = try sandboxes.make(named: "kept-blocked")
        let blocked = root.appendingPathComponent("not-a-folder")
        try Data("a file where the copies would go".utf8).write(to: blocked)
        let f = Folders(pending: PendingScoutIngests(directory: blocked.appendingPathComponent("pending"),
                                                     readFailures: HandoffReadFailures()),
                        journals: LandingJournals(directory: root.appendingPathComponent("journals"),
                                                  readFailures: HandoffReadFailures()))

        let landed = try await land(try data(["a"]), into: ctx, f, lines: Lines())
        guard case .resultsNotKept? = landed.outcome.landingStop else {
            Issue.record(Comment(rawValue: "a landing that could not keep its results was not refused: "
                                 + String(describing: landed.outcome.landingStop)))
            return
        }
        #expect(try titles(c).isEmpty, "a landing that could not keep its results applied them")
        #expect(landed.outcome.sources.map(\.state) == [.notAttempted])
        #expect(try sources(c)["a"]?.lastContentHash == "old-a")
        #expect(try f.journals.list().isEmpty, "a journal was written for a landing that never began")
        #expect(landed.outcome.notLandedYet?.contains("reader's results file") == true, Comment(rawValue:
            "the refusal did not say where the results still are: \(landed.outcome.notLandedYet ?? "nothing")"))
        // L11: named as the copy that failed, never as the landing record, and the copy is not blamed twice.
        #expect(landed.outcome.landingStopWarning?.contains("couldn't keep a copy of these calendar results") == true)
        #expect(landed.outcome.notLandedYet?.contains("either") == false)
    }

    // L11: a copy that failed is not tried again through the refusal's own keep a copy path. A retry that then
    // succeeded would leave the refusal saying no copy was kept while one is.
    @Test func aCopyThatCannotBeKeptIsNotRetriedBehindItsOwnRefusal() async throws {
        let c = try container()
        let ctx = c.mainContext
        html("a", in: ctx)
        try ctx.save()
        struct CopyRefused: Error {}
        var retried = 0
        let outcome = await ScoutExtractIngest.ingest(
            try ScoutExtractResultsDecoder.decode(try data(["a"])), clients: [], history: [], blocked: .empty,
            today: today, now: now, landings: LandingSingleFlight(sleep: { _ in }), sequenceFloor: { 0 },
            onRefused: { _ in retried += 1 }, keepResults: { _ in throw CopyRefused() }, into: ctx)
        guard case .resultsNotKept? = outcome.landingStop else {
            Issue.record(Comment(rawValue: "a copy that failed was not refused: \(String(describing: outcome.landingStop))"))
            return
        }
        #expect(retried == 0, "the refusal tried the copy that had just failed again")
        #expect(try titles(c).isEmpty)
    }

    // MARK: - #4335: offered again, nothing is counted twice

    // The plan's test: a landing interrupted between source N's save and N+1's, then offered again, moves each
    // source's check once, records each source's miss once, appends one movement line per source that landed,
    // and leaves the earlier source reported as landed rather than reapplied. Seen to fail by applying an
    // earlier landed source's bookkeeping again.
    @Test func aLandingInterruptedBetweenTwoSourcesAndOfferedAgainCountsEverySourceOnce() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b", "c"] { html(id, in: ctx) }
        try ctx.save()
        let f = try folders("replay-once")
        let lines = Lines()
        let failing = FailOne("b")

        let first = try await land(try data(["a", "b", "c"]), into: ctx, f, lines: lines, saveSource: failing.save,
                                   saveClosing: { _ in throw SaveRefused() })
        #expect(first.outcome.saveFailed)
        // The store as a crash at that point leaves it: a landed, b and c not.
        var stored = try sources(c)
        #expect(stored["a"]?.successfulCheckCount == WatchedSource.warmupRuns + 1)
        #expect(stored["a"]?.lastContentHash == "new-a", "a's page hash did not ride a's own save")
        #expect(stored["b"]?.successfulCheckCount == WatchedSource.warmupRuns)
        #expect(try titles(c) == ["Recital a 0", "Recital a 1"])
        #expect(try shows(c)["gone-a"]?.missedScoutCount == 0, "the reconcile rode a closing save that failed")
        #expect(lines.count("a") == 1 && lines.count("b") == 0)

        let offered = await offer(into: ctx, f, lines: lines)
        #expect(offered.landed.count == 1, Comment(rawValue: "the kept results did not land: \(offered)"))
        stored = try sources(c)
        for id in ["a", "b", "c"] {
            #expect(stored[id]?.successfulCheckCount == WatchedSource.warmupRuns + 1, Comment(rawValue:
                "\(id) counted \((stored[id]?.successfulCheckCount ?? 0) - WatchedSource.warmupRuns) checks"))
            #expect(stored[id]?.lastContentHash == "new-\(id)")
            #expect(lines.count(id) == 1, Comment(rawValue: "\(id) appended \(lines.count(id)) movement lines"))
            #expect(try shows(c)["gone-\(id)"]?.missedScoutCount == 1, Comment(rawValue:
                "\(id)'s miss was counted \((try? shows(c)["gone-\(id)"]?.missedScoutCount) ?? -1) times"))
        }
        #expect(try titles(c).count == 6)
        #expect(try f.pending.list().isEmpty && f.journals.list().isEmpty)
        let runs = try ModelContext(c).fetch(FetchDescriptor<LandingRun>())
        #expect(runs.count == 1 && runs.first?.landedAt != nil, "the run was recorded \(runs.count) times")
    }

    // The plan's byte-identical guard: a landing interrupted and offered again leaves every stored property
    // of every entity (the landing oracle's snapshot, which leaves out only the clock stamps it lists) exactly
    // as the same results landed once, cleanly, leave it.
    @Test func anInterruptedLandingOfferedAgainLeavesWhatOneCleanLandingLeaves() async throws {
        func seeded() throws -> ModelContainer {
            let c = try container()
            for id in ["a", "b", "c"] { html(id, in: c.mainContext) }
            try c.mainContext.save()
            return c
        }
        let bytes = try data(["a", "b", "c"])
        let clean = try seeded()
        _ = try await land(bytes, into: clean.mainContext, try folders("replay-clean"), lines: Lines())

        let replayed = try seeded()
        let f = try folders("replay-interrupted")
        let failing = FailOne("b")
        _ = try await land(bytes, into: replayed.mainContext, f, lines: Lines(), saveSource: failing.save,
                           saveClosing: { _ in throw SaveRefused() })
        _ = await offer(into: replayed.mainContext, f, lines: Lines())

        let differences = LandingOracle.differences(
            expected: LandingOracle.recording(of: try LandingOracle.snapshot(of: clean)),
            actual: try LandingOracle.snapshot(of: replayed), arm: .synthetic)
        #expect(differences.isEmpty, Comment(rawValue: differences.joined(separator: "\n")))
    }

    // A replay promotes the page hash its journal recorded for a source, the page its results were read from,
    // never a newer one left pending on the row since.
    @Test func aReplayPromotesThePageItsResultsWereReadFromNeverANewerOne() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b"] { html(id, in: ctx) }
        try ctx.save()
        let f = try folders("replay-hash")
        let failing = FailOne("b")
        _ = try await land(try data(["a", "b"]), into: ctx, f, lines: Lines(), saveSource: failing.save,
                           saveClosing: { _ in throw SaveRefused() })
        // A newer page left pending on b by something that is not a landing, so b's sequence does not move. On the
        // landing's own context, which is the one the replay reads b through.
        let b = try #require(try ctx.fetch(FetchDescriptor<WatchedSource>()).first { $0.sourceId == "b" })
        b.pendingContentHash = "newer-b"
        try ctx.save()

        _ = await offer(into: ctx, f, lines: Lines())
        #expect(try sources(c)["b"]?.lastContentHash == "new-b", Comment(rawValue:
            "the replay marked \(String(describing: try? sources(c)["b"]?.lastContentHash)) read"))
    }
}
