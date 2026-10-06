import Testing
import Foundation
import SwiftData

// #4335 (A6, the first part): every scout landing is recorded, outside the store (its journal, the INTENT)
// and in it (a `LandingRun` row, and on each source it landed, the run that landed it, in the same save as
// the source's shows). An interrupted landing is then a journal still on disk, read against what the store
// says landed. The recovery that reads it is the rest of #4335.
@MainActor
@Suite("Every scout landing is recorded, in a journal and in the store (#4335)")
final class ScoutLandingRecordTests {
    private let sandboxes = TemporarySandboxes()
    private let now = Date(timeIntervalSince1970: 1_790_000_000.25)
    private struct SaveRefused: Error {}

    private func container() throws -> ModelContainer {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        c.mainContext.autosaveEnabled = false
        return c
    }

    private func journals(_ name: String, failures: HandoffReadFailures = HandoffReadFailures()) throws -> LandingJournals {
        LandingJournals(directory: try sandboxes.make(named: name).appendingPathComponent("journals"),
                        readFailures: failures)
    }

    private func night(_ n: Int) -> String {
        EasternDate.dayString(from: Calendar(identifier: .gregorian).date(byAdding: .day, value: 30 + n, to: now)!)
    }

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

    private func result(_ id: String) -> ScoutExtractResult {
        ScoutExtractResult(sourceId: id, verdict: .upcomingListings,
                           events: (0..<2).map { k in
                               ScoutExtractEvent(title: "Recital \(id) \(k)", presenter: "Recital \(id) \(k)",
                                                 venue: "Merkin Hall", performanceDate: night(k),
                                                 sourceUrl: "https://\(id).example/r\(k)")
                           },
                           note: nil)
    }

    private func results(_ ids: [String]) -> ScoutExtractResults {
        ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z", results: ids.map(result))
    }

    private func ingest(_ r: ScoutExtractResults, into ctx: ModelContext, journals: LandingJournals?,
                        flight: LandingSingleFlight = LandingSingleFlight(sleep: { _ in }),
                        saveSource: @escaping (ModelContext) throws -> Void = { try $0.save() },
                        identity: String = "results-hash") async -> ScoutService.Outcome {
        await ScoutExtractIngest.ingest(r, clients: [], history: [], blocked: .empty,
                                        today: ScoutTestClock.beforeAllFixtures, now: now, landings: flight,
                                        identity: LandedResultsIdentity(contentHash: identity, check: .lookUp),
                                        sequenceFloor: { 0 }, saveSource: saveSource, journals: journals,
                                        into: ctx)
    }

    private static let ovationTix = """
        [{"date":"%@","productions":[{"productionId":1,"name":"Bone Wars"}]}]
        """

    private func inlinePage(_ url: URL) -> FetchedPage {
        let json = Data(String(format: Self.ovationTix, night(1)).utf8)
        return FetchedPage(normalizedHTML: "<p/>", finalURL: "https://web.ovationtix.com/trs/cal/277",
                           contentHash: "inline-new-\(url.host ?? "")", followedTicketLinkFrom: url.absoluteString,
                           ticketingFeedURL: "https://web.ovationtix.com/trs/cal/277", ticketingFeedJSON: json)
    }

    private func runScout(_ ctx: ModelContext, journals: LandingJournals?,
                          flight: LandingSingleFlight = LandingSingleFlight(sleep: { _ in }),
                          saveSource: @escaping (ModelContext) throws -> Void = { try $0.save() })
        async throws -> ScoutService.Outcome {
        try await ScoutService.runScout(
            into: ctx, depth: .readChanged,
            fetch: { url, _, _ in self.inlinePage(url) },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            now: now, defaults: ScratchDefaults.make("ScoutLandingRecordTests"),
            landings: flight, sequenceFloor: { 0 }, saveSource: saveSource, journals: journals)
    }

    private func runs(_ c: ModelContainer) throws -> [LandingRun] {
        try ModelContext(c).fetch(FetchDescriptor<LandingRun>(sortBy: [SortDescriptor(\.sequence)]))
    }

    private func source(_ id: String, _ c: ModelContainer) throws -> WatchedSource {
        try #require(try ModelContext(c).fetch(FetchDescriptor<WatchedSource>()).first { $0.sourceId == id })
    }

    private func pendingJournals(_ j: LandingJournals) throws -> [LandingJournal] {
        try j.list().compactMap { if case .pending(let journal, _) = $0 { return journal }; return nil }
    }

    // A save that fails the first time it carries the named source's row.
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

    // MARK: - what a finished landing leaves

    @Test func anIngestRecordsItsLandingAndTheRunOnEverySourceItLanded() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b"] { html(id, in: ctx) }
        try ctx.save()
        let j = try journals("record-ingest")

        let outcome = await ingest(results(["a", "b"]), into: ctx, journals: j)

        #expect(!outcome.saveFailed && outcome.landingStop == nil)
        let run = try #require(try runs(c).first)
        #expect(try runs(c).count == 1)
        #expect(run.runIdentity == "results-hash")
        #expect(run.entryPointRaw == LandingSingleFlight.EntryPoint.scoutExtractIngest.rawValue)
        #expect(run.startedAt == now)
        #expect(run.landedAt == now)
        for id in ["a", "b"] {
            let s = try source(id, c)
            #expect(s.lastLandedRunID == "results-hash", Comment(rawValue: "\(id): \(s.lastLandedRunID ?? "nil")"))
            #expect(s.lastLandedSequence == run.sequence && run.sequence == s.lastTouchedSequence && run.sequence > 0,
                    Comment(rawValue: "\(id): landed \(s.lastLandedSequence) touched \(s.lastTouchedSequence) run \(run.sequence)"))
        }
        #expect(try j.list().isEmpty, "a landing that finished left its journal behind")
    }

    @Test func aRunScoutRecordsItsLandingAndTheRunOnEverySourceItLanded() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["inline-a", "inline-b"] { html(id, in: ctx) }
        try ctx.save()
        let j = try journals("record-runscout")

        let outcome = try await runScout(ctx, journals: j)

        #expect(!outcome.saveFailed && outcome.landingStop == nil)
        let run = try #require(try runs(c).first)
        #expect(try runs(c).count == 1)
        #expect(run.runIdentity.hasPrefix("sweep-"))
        #expect(run.entryPointRaw == LandingSingleFlight.EntryPoint.runScoutLanding.rawValue)
        #expect(run.startedAt == now && run.landedAt == now)
        for id in ["inline-a", "inline-b"] {
            let s = try source(id, c)
            #expect(s.lastLandedRunID == run.runIdentity, Comment(rawValue: "\(id): \(s.lastLandedRunID ?? "nil")"))
            #expect(s.lastLandedSequence == run.sequence && run.sequence > 0)
        }
        #expect(try j.list().isEmpty, "a run that finished left its journal behind")
    }

    // The journal is on disk BEFORE the first source applies, holding the intent: the run, its sequence, the
    // entry point, the sources in order with each page's hash as it stood at landing start, and the landing's
    // own `now`. Read from inside the first source's save, which is the moment a crash would leave it.
    @Test func theJournalIsWrittenBeforeAnySourceAppliesAndHoldsTheIntent() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b"] { html(id, in: ctx) }
        try ctx.save()
        let j = try journals("record-intent")
        var seen: [LandingJournal] = []
        var landedAtTheFirstSave = 0

        _ = await ingest(results(["a", "b"]), into: ctx, journals: j, saveSource: { context in
            if seen.isEmpty {
                seen = (try? self.pendingJournals(j)) ?? []
                landedAtTheFirstSave = (try? ModelContext(c).fetch(FetchDescriptor<Prospect>()).count) ?? -1
            }
            try context.save()
        })

        #expect(landedAtTheFirstSave == 0, "the journal was looked for after a source had already saved")
        let journal = try #require(seen.first, "no journal was on disk when the first source saved")
        #expect(seen.count == 1)
        #expect(journal.version == LandingJournal.currentVersion)
        #expect(journal.runIdentity == "results-hash")
        #expect(journal.entryPoint == LandingSingleFlight.EntryPoint.scoutExtractIngest.rawValue)
        #expect(journal.sequence == (try source("a", c)).lastLandedSequence)
        #expect(journal.now == now)
        // #4440: and, from version 2, what each landing source's report is judged against as the run started.
        #expect(journal.sources == [.init(sourceId: "a", pageHash: "new-a", checksBefore: 0, baselineBefore: 0),
                                    .init(sourceId: "b", pageHash: "new-b", checksBefore: 0, baselineBefore: 0)])
    }

    // MARK: - what an interrupted landing leaves

    // The second source's save fails at store level, so the landing stops after the first. What the store says
    // then is the whole of what recovery needs beside the journal: the landing record (unlanded, carried by the
    // first save), the first source stamped with the run, and the second exactly as it was.
    @Test func aLandingStoppedAfterItsFirstSaveKeepsItsJournalAndTheStoreSaysWhichSourcesLanded() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b"] { html(id, in: ctx) }
        try ctx.save()
        let j = try journals("record-stopped")
        let failing = FailOne("b")

        let outcome = await ingest(results(["a", "b"]), into: ctx, journals: j, saveSource: failing.save)

        #expect(failing.refused == 1, "the second source's save was never refused")
        #expect(outcome.landingStop == .storeRefusedASave(source: "Org b"))
        let run = try #require(try runs(c).first, "the record of a landing that started never reached the store")
        #expect(run.landedAt == nil)
        #expect(try source("a", c).lastLandedRunID == "results-hash")
        #expect(try source("a", c).lastLandedSequence == run.sequence)
        #expect(try source("b", c).lastLandedRunID == nil, "a source whose save failed was recorded as landed")
        #expect(try source("b", c).lastLandedSequence == 0)
        let kept = try pendingJournals(j)
        #expect(kept.map(\.sequence) == [run.sequence], "an interrupted landing's journal was not kept")
    }

    // A source-level failure puts that one source back and the landing goes on. The landing record is not the
    // failed source's write, so the revert must not take it: the next save carries it.
    @Test func aSourcePutBackLeavesTheLandingRecordForTheNextSaveToCarry() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b"] { html(id, in: ctx) }
        try ctx.save()
        let failing = FailOne("a")

        let outcome = await ScoutExtractIngest.ingest(
            results(["a", "b"]), clients: [], history: [], blocked: .empty,
            today: ScoutTestClock.beforeAllFixtures, now: now, landings: LandingSingleFlight(sleep: { _ in }),
            sequenceFloor: { 0 }, saveSource: failing.save, classifySaveFailure: { _ in .source }, into: ctx)

        #expect(failing.refused == 1)
        #expect(outcome.saveFailed && outcome.landingStop == nil)
        let run = try #require(try runs(c).first, "the source revert took the landing record with it")
        #expect(run.landedAt == nil, "a landing with a source put back was stamped as landed")
        #expect(try source("a", c).lastLandedRunID == nil)
        #expect(try source("b", c).lastLandedRunID == run.runIdentity)
    }

    // MARK: - a journal that cannot be written

    // L258: a landing that cannot record its intent is not begun. The journal folder's path is a FILE, so the
    // start write fails; nothing is applied, nothing is recorded in the store, and the refusal says why.
    @Test func anIngestWhoseJournalCannotBeWrittenAppliesNothing() async throws {
        let c = try container()
        let ctx = c.mainContext
        html("a", in: ctx)
        try ctx.save()
        let blocked = try sandboxes.make(named: "record-unwritable").appendingPathComponent("journals")
        try Data("not a folder".utf8).write(to: blocked)
        var refusedWith: Int?

        let outcome = await ScoutExtractIngest.ingest(
            results(["a"]), clients: [], history: [], blocked: .empty,
            today: ScoutTestClock.beforeAllFixtures, now: now, landings: LandingSingleFlight(sleep: { _ in }),
            sequenceFloor: { 0 }, onRefused: { refusedWith = $0 },
            journals: LandingJournals(directory: blocked, readFailures: HandoffReadFailures()), into: ctx)

        guard case .journalNotWritten? = outcome.landingStop else {
            Issue.record(Comment(rawValue: "the landing was not refused: \(String(describing: outcome.landingStop))"))
            return
        }
        #expect(refusedWith != nil, "the caller was not told to keep the results")
        #expect(outcome.sources.map(\.state) == [.notAttempted])
        #expect(try ModelContext(c).fetch(FetchDescriptor<Prospect>()).isEmpty)
        #expect(try runs(c).isEmpty)
        #expect(!ctx.hasChanges, "a refused landing left writes pending")
        let s = try source("a", c)
        #expect(s.lastContentHash == "old" && s.hasUnreadChanges && s.lastTouchedSequence == 0)
        let said = try #require(outcome.landingStopWarning)
        #expect(said.contains("couldn't write the record it keeps while it saves a scout"))
        #expect(!said.contains("not landed"), Comment(rawValue: "a refusal before anything said sources went unlanded: \(said)"))
    }

    @Test func aRunScoutWhoseJournalCannotBeWrittenAppliesNothing() async throws {
        let c = try container()
        let ctx = c.mainContext
        html("inline-a", in: ctx)
        try ctx.save()
        let blocked = try sandboxes.make(named: "record-unwritable-runscout").appendingPathComponent("journals")
        try Data("not a folder".utf8).write(to: blocked)

        let outcome = try await runScout(ctx, journals: LandingJournals(directory: blocked,
                                                                         readFailures: HandoffReadFailures()))

        guard case .journalNotWritten? = outcome.landingStop else {
            Issue.record(Comment(rawValue: "the run was not refused: \(String(describing: outcome.landingStop))"))
            return
        }
        #expect(try ModelContext(c).fetch(FetchDescriptor<Prospect>()).isEmpty)
        #expect(try runs(c).isEmpty)
        let s = try source("inline-a", c)
        #expect(s.lastContentHash == "old" && s.lastTouchedSequence == 0 && s.lastLandedRunID == nil)
    }

    // MARK: - the sequence, from the store and the journal names, never the clock (L186)

    @Test func aLandingAfterARelaunchMintsAboveTheLastOne() async throws {
        let c = try container()
        let ctx = c.mainContext
        html("a", in: ctx)
        try ctx.save()
        let j = try journals("sequence-relaunch")

        _ = await ingest(results(["a"]), into: ctx, journals: j, identity: "first")
        // A fresh flight is a fresh process: nothing in memory remembers the first mint.
        _ = await ingest(results(["a"]), into: ctx, journals: j, flight: LandingSingleFlight(sleep: { _ in }),
                         identity: "second")

        let all = try runs(c)
        #expect(all.map(\.runIdentity) == ["first", "second"])
        #expect(all.count == 2 && all[1].sequence > all[0].sequence)
    }

    // The store's landing record is a floor of its own: a landing whose sources were all set aside still saved
    // its number, and no source carries it.
    @Test func aLandingMintsAboveTheHighestLandingRecord() async throws {
        let c = try container()
        let ctx = c.mainContext
        html("a", in: ctx)
        ctx.insert(LandingRun(runIdentity: "earlier", landedAt: now, sequence: 70))
        try ctx.save()

        _ = await ingest(results(["a"]), into: ctx, journals: try journals("sequence-record"))

        #expect(try runs(c).map(\.sequence) == [70, 71])
    }

    // A crash before the first save leaves a journal holding a sequence the store never saw.
    @Test func aLandingMintsAboveAJournalTheStoreNeverSaw() async throws {
        let c = try container()
        let ctx = c.mainContext
        html("a", in: ctx)
        try ctx.save()
        let j = try journals("sequence-journal")
        try j.start(LandingJournal(runIdentity: "crashed", sequence: 41, entryPoint: .scoutExtractIngest,
                                   sources: [.init(sourceId: "a", pageHash: "new-a")], now: now))

        _ = await ingest(results(["a"]), into: ctx, journals: j)

        #expect(try runs(c).map(\.sequence) == [42])
        #expect(try pendingJournals(j).map(\.runIdentity) == ["crashed"], "another run's journal was touched")
    }

    // L371: one bad journal cannot stop every landing. Its NAME still carries its sequence, so a landing mints
    // above it and lands; listing the folder quarantines it by renaming, lists it by path, and the name keeps
    // counting. #4338 (A10): the path is said by the landing line, its own surface, with "Try again" and
    // "Discard", so it is no longer also recorded for the generic file notice.
    @Test func anUnreadableJournalIsQuarantinedAndNeverStopsALanding() async throws {
        let c = try container()
        let ctx = c.mainContext
        html("a", in: ctx)
        try ctx.save()
        let failures = HandoffReadFailures()
        let j = try journals("sequence-corrupt", failures: failures)
        try FileManager.default.createDirectory(at: j.directory, withIntermediateDirectories: true)
        let corrupt = j.directory.appendingPathComponent(LandingJournals.fileName(sequence: 57, runIdentity: "torn"))
        try Data("{\"version\": 1, \"runIdent".utf8).write(to: corrupt)

        let outcome = await ingest(results(["a"]), into: ctx, journals: j)
        #expect(!outcome.saveFailed && outcome.landingStop == nil)
        #expect(try runs(c).map(\.sequence) == [58])

        let listed = try j.list()
        guard case .quarantined(let path, let sequence, _)? = listed.first, listed.count == 1 else {
            Issue.record(Comment(rawValue: "the unreadable journal was not quarantined: \(listed)"))
            return
        }
        #expect(sequence == 57)
        #expect(path.hasSuffix(LandingJournals.quarantineSuffix))
        #expect(!FileManager.default.fileExists(atPath: corrupt.path))
        #expect(!failures.current().contains { $0.reason.contains("could not read the landing record") },
                Comment(rawValue: "said in the file notice as well as on the landing line: \(failures.current())"))

        _ = await ingest(results(["a"]), into: ctx, journals: j, flight: LandingSingleFlight(sleep: { _ in }),
                         identity: "after")
        #expect(try runs(c).map(\.sequence) == [58, 59])
    }

    // MARK: - the journal file itself

    @Test func aJournalsNameCarriesItsSequenceZeroPadded() {
        let name = LandingJournals.fileName(sequence: 42, runIdentity: "sweep-AB/12")
        #expect(name == "0000000042-sweep-AB_12.json")
        #expect(LandingJournals.sequence(inName: name) == 42)
        #expect(LandingJournals.sequence(inName: name + LandingJournals.quarantineSuffix) == 42)
        #expect(LandingJournals.sequence(inName: ".incoming-1234") == nil)
        #expect(LandingJournals.sequence(inName: "notes.txt") == nil)
    }

    @Test func aStartWriteLeavesOneWholeJournalAndNoTemporaryFile() throws {
        let j = try journals("file-start")
        let journal = LandingJournal(runIdentity: "r", sequence: 3, entryPoint: .runScoutLanding,
                                     sources: [.init(sourceId: "a", pageHash: nil)], now: now)
        try j.start(journal)
        try j.start(journal)   // a kept copy offered again writes the same run's journal again

        #expect(try FileManager.default.contentsOfDirectory(atPath: j.directory.path)
                    == [LandingJournals.fileName(sequence: 3, runIdentity: "r")])
        #expect(try pendingJournals(j) == [journal])
        j.retire(journal)
        #expect(try FileManager.default.contentsOfDirectory(atPath: j.directory.path).isEmpty)
    }

    // Each version is decoded by the version it was written under, held by a committed file per version.
    @Test func aVersionOneJournalStillDecodes() throws {
        let data = try Data(contentsOf: RepoRoot.url.appendingPathComponent("fixtures/landing-journal/v1.json"))
        let journal = try LandingJournals.decode(data)
        #expect(journal.version == 1)
        #expect(journal.runIdentity == "0123abcd" && journal.sequence == 12)
        #expect(journal.entryPoint == LandingSingleFlight.EntryPoint.scoutExtractIngest.rawValue)
        #expect(journal.now == Date(timeIntervalSinceReferenceDate: 780_000_000.5))
        #expect(journal.sources == [.init(sourceId: "a", pageHash: "page-a"), .init(sourceId: "b", pageHash: nil)])
        // #4440: carried forward with nothing invented. A version 1 journal never recorded a results copy or
        // what its sources stood at, and reads back saying so.
        #expect(journal.resultsCopy == nil)
        #expect(journal.sources.allSatisfy { $0.checksBefore == nil && $0.baselineBefore == nil })
        // Written again (a kept copy offered again writes the same run's journal again), it is written in the
        // shape this build writes, under the version that names that shape, never "version 1" over v2 fields
        // that the next read would then decode as version 1 and drop (L1010).
        let rewritten = try LandingJournals.decode(LandingJournals.encoded(journal))
        #expect(rewritten.version == LandingJournal.currentVersion)
        #expect(rewritten.runIdentity == journal.runIdentity && rewritten.sources == journal.sources)
    }

    // #4440: version 2, the results copy and what each landing source's report is judged against.
    @Test func aVersionTwoJournalDecodes() throws {
        let data = try Data(contentsOf: RepoRoot.url.appendingPathComponent("fixtures/landing-journal/v2.json"))
        let journal = try LandingJournals.decode(data)
        #expect(journal.version == 2)
        #expect(journal.resultsCopy == "0123abcd")
        #expect(journal.sources == [.init(sourceId: "a", pageHash: "page-a", checksBefore: 4, baselineBefore: 3),
                                    .init(sourceId: "b", pageHash: nil)])
        #expect(journal.now == Date(timeIntervalSinceReferenceDate: 780_000_000.5))
        // And what this build writes is what it reads back, at the current version.
        #expect(try LandingJournals.decode(LandingJournals.encoded(journal)) == journal)
        #expect(LandingJournal.currentVersion == 2)
    }

    @Test func aJournalOfAVersionThisBuildDoesNotKnowIsRefusedNotReadAsTheCurrentOne() {
        let future = Data("{\"version\":99,\"runIdentity\":\"r\",\"sequence\":1,\"entryPoint\":\"x\",\"sources\":[],\"now\":1}".utf8)
        #expect(throws: LandingJournals.UnknownVersion.self) { try LandingJournals.decode(future) }
    }

    // L255: a journal from a NEWER build is not a corrupt one. It is reported and left where it is, so the
    // build that reads it can still recover it, rather than renamed out of every later recovery.
    @Test func aJournalFromANewerBuildIsReportedAndLeftInPlace() throws {
        let failures = HandoffReadFailures()
        let j = try journals("file-newer", failures: failures)
        try FileManager.default.createDirectory(at: j.directory, withIntermediateDirectories: true)
        let newer = j.directory.appendingPathComponent(LandingJournals.fileName(sequence: 9, runIdentity: "next"))
        try Data("{\"version\":\(LandingJournal.currentVersion + 1),\"runIdentity\":\"next\"}".utf8).write(to: newer)

        let listed = try j.list()

        guard case .leftInPlace(let path, let sequence, _)? = listed.first, listed.count == 1 else {
            Issue.record(Comment(rawValue: "a newer build's journal was not left in place: \(listed)"))
            return
        }
        #expect(path == newer.path && sequence == 9)
        #expect(FileManager.default.fileExists(atPath: newer.path), "a newer build's journal was renamed away")
        #expect(failures.current().contains { $0.reason.contains("version \(LandingJournal.currentVersion + 1) is not one this build reads") },
                Comment(rawValue: "\(failures.current())"))
        #expect(j.highestSequence == 9)
    }

    // A journal the disk will not hand over right now (here, no read permission) is not corrupt either: it
    // is reported and left in place for the next listing, never renamed away.
    @Test func aJournalThatCannotBeReadFromDiskIsReportedAndLeftInPlace() throws {
        let failures = HandoffReadFailures()
        let j = try journals("file-unreadable", failures: failures)
        let journal = LandingJournal(runIdentity: "locked", sequence: 4, entryPoint: .scoutExtractIngest,
                                     sources: [], now: now)
        let url = try j.start(journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        let listed = try j.list()

        guard case .leftInPlace(let path, let sequence, _)? = listed.first, listed.count == 1 else {
            Issue.record(Comment(rawValue: "a journal that could not be read from disk was not left in place: \(listed)"))
            return
        }
        #expect(path == url.path && sequence == 4)
        #expect(FileManager.default.fileExists(atPath: url.path), "an unreadable journal was renamed away")
        #expect(failures.current().contains { $0.reason.contains("could not read the landing record at \(url.path)") },
                Comment(rawValue: "\(failures.current())"))
    }

    // A sequence past 32 bits keeps its whole value in the name, so the name floor never reads it low.
    @Test func aSequencePastThirtyTwoBitsSurvivesTheName() {
        let big = 5_000_000_123
        #expect(LandingJournals.sequence(inName: LandingJournals.fileName(sequence: big, runIdentity: "r")) == big)
    }

    // The original `now` survives the file exactly, which a whole-second date format would not.
    @Test func theLandingsNowSurvivesTheJournalExactly() throws {
        let journal = LandingJournal(runIdentity: "r", sequence: 1, entryPoint: .scoutExtractIngest,
                                     sources: [], now: now)
        #expect(try LandingJournals.decode(LandingJournals.encoded(journal)).now == now)
    }
}
