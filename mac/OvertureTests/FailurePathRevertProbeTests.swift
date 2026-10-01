import Testing
import Foundation
import Darwin
import SwiftData

// #4327 step 0.8: the failure path revert, candidate (ii) only (decision 2), and its correctness cases, each a
// test (L246, L574). The revert itself is `FailurePathRevert`, beside this file.
//
// THE FAILURE IS REAL. Every failed save here is a genuine SwiftData save failure: the store file is flagged
// immutable before the landing's container opens it (as `ImmutableStoreFixture` does, #617), so the source's
// own `ScoutService.apply` save throws and the source reports `saveFailed`. The entry flush (A3/A5) is
// modelled by what it does: the pre-landing edit is SAVED before the store starts refusing, so it is
// committed when the failed turn begins. Without the flush the same edit is made, unsaved, in the landing's
// own context.
//
// WHAT "A LATER SAVE" MEANS HERE, and why it is not a second save. A refusal that can be switched OFF on the
// same context was looked for and not found, each measured on 2026-09-29: a duplicate natural key does not
// fail a save at all (SwiftData upserts it); an immutable store opens its connection read only for the
// container's whole life, so clearing the flags leaves every later save failing too; and a SQLite trigger
// that aborts writes makes Core Data read the abort as an optimistic locking failure it cannot resolve, and
// it ends the PROCESS ("fatal: Unable to recover from optimistic locking failure"), never throws. So each
// case asserts on what a later save would carry: the context read through ITSELF (every row as the context
// holds it, unsaved values included, unsaved inserts included) against the committed store read through a
// fresh context. Equal means a later save writes nothing of the failed turn and keeps what was committed.
// The instances the landing already held are checked too, which is the thing `rollback()` gets wrong.
@MainActor
@Suite("The failure path revert restores what a failed save carried (#4327 step 0.8)", .serialized)
final class FailurePathRevertProbeTests {
    private let sandboxes = TemporarySandboxes()
    private static let room = "Merkin Hall"
    private static let night = "2099-10-01"
    private static let url = "https://src-a.example/rondo"

    // MARK: a store that refuses saves

    final class RefusingStore {
        let url: URL
        private(set) var container: ModelContainer?
        init(url: URL) { self.url = url }

        /// Flags the store immutable, then opens the container the landing runs on, autosave off, so every
        /// save it attempts fails.
        @MainActor func openRefusing() throws -> ModelContext {
            for suffix in ["", "-wal", "-shm"] { _ = chflags(url.path + suffix, UInt32(UF_IMMUTABLE)) }
            let c = try FileStores.container(for: AppSchema.schema,
                                       configurations: [ModelConfiguration(schema: AppSchema.schema, url: url)])
            container = c
            c.mainContext.autosaveEnabled = false
            return c.mainContext
        }

        /// Takes the flags off, so the sandbox can be removed.
        func release() {
            for suffix in ["", "-wal", "-shm"] { _ = chflags(url.path + suffix, 0) }
        }
    }

    private struct Seeded {
        let store: RefusingStore
        let committed: [String: [String]]
    }

    private func show(_ key: String, _ title: String, url: String?) -> Prospect {
        Prospect(naturalKey: key, groupName: title, discipline: "music", venue: Self.room,
                 performanceDate: Self.night, sourceListingURL: url, priorRelationship: "none",
                 production: "self", profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                 fitReason: "r", matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
    }

    // One watched source, the show it re-lists (with two contacts and a run URL), and an unrelated show.
    // `flushed` runs against the seed context before the save, which is the entry flush's effect.
    private func seed(_ name: String, flushed: (ModelContext) throws -> Void = { _ in }) throws -> Seeded {
        let dir = try sandboxes.make(named: "revert-\(name)")
        let url = dir.appendingPathComponent("Overture.store")
        do {
            let c = try FileStores.container(for: AppSchema.schema,
                                       configurations: [ModelConfiguration(schema: AppSchema.schema, url: url)])
            let ctx = ModelContext(c)
            let source = WatchedSource(sourceId: "src-a", orgName: "Org A", listingsURL: "https://src-a.example/",
                                       kind: .html)
            source.lastDroppedShowLabelsRaw = "Old Label"
            ctx.insert(source)
            let rondo = show("rondo-key", "Rondo Night", url: Self.url)
            rondo.runSourceURLs = [Self.url]
            rondo.sourceIds = ["src-a"]
            ctx.insert(rondo)
            for (id, email) in [("r1", "one@rondo.example"), ("r2", "two@rondo.example")] {
                let r = Recipient(id: id, email: email, provenance: .presenter)
                ctx.insert(r)
                rondo.recipients.append(r)
            }
            ctx.insert(show("elsewhere-key", "Elsewhere Night", url: "https://other.example/elsewhere"))
            try ctx.save()
            try flushed(ctx)
            try ctx.save()
        }
        let committed = try Self.snapshot(ModelContext(try FileStores.container(
            for: AppSchema.schema, configurations: [ModelConfiguration(schema: AppSchema.schema, url: url)])))
        return Seeded(store: RefusingStore(url: url), committed: committed)
    }

    // Every stored field of every show, contact and watched source, keyed by the row's own identity, with
    // relationships as the sorted identities of their members. Read through whatever context is passed: a
    // fresh one reads the store, the landing's own reads what a save from it would write. Keyed by the
    // fixture's natural identities (natural key, contact id, source id) rather than `persistentModelID`,
    // whose printed form differs between two containers opened on the same file (measured: every row read
    // as present in only one of the two snapshots, with no field differing).
    static func snapshot(_ ctx: ModelContext) throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        func identity(_ model: any PersistentModel) -> String {
            switch model {
            case let p as Prospect: return "Prospect " + p.naturalKey
            case let r as Recipient: return "Recipient " + r.id
            case let w as WatchedSource: return "WatchedSource " + w.sourceId
            default: return "\(type(of: model)) \(model.persistentModelID)"
            }
        }
        func render(_ value: Any?) -> String {
            guard let value else { return "nil" }
            if let members = value as? [any PersistentModel] {
                return members.map(identity).sorted().joined(separator: ",")
            }
            if let model = value as? any PersistentModel { return identity(model) }
            if value is any RevertOptionalModel { return "nil" }
            return String(describing: value)
        }
        func add<M: ScopeObserved>(_: M.Type) throws {
            for row in try ctx.fetch(FetchDescriptor<M>()) {
                out[identity(row)] = M.scopeFields.map { render(row[keyPath: $0.keyPath]) }
            }
        }
        try add(Prospect.self)
        try add(Recipient.self)
        try add(WatchedSource.self)
        return out
    }

    // Fixture values only (invented shows and contacts), so naming them is safe.
    private static func differences(_ a: [String: [String]], _ b: [String: [String]]) -> String {
        let only = Set(a.keys).symmetricDifference(b.keys).sorted()
        var fields: [String] = []
        for (key, values) in a.sorted(by: { $0.key < $1.key }) {
            guard let other = b[key], other != values else { continue }
            for i in values.indices where i < other.count && values[i] != other[i] {
                fields.append("\(key.prefix(20)) field \(i): \(values[i].prefix(60)) against \(other[i].prefix(60))")
            }
        }
        return "rows in only one: \(only.map { String($0.prefix(24)) }); fields differing: \(fields)"
    }

    private func held<M: PersistentModel>(_ ctx: ModelContext, _: M.Type) throws -> [M] {
        try ctx.fetch(FetchDescriptor<M>())
    }

    private func committedRow(_ ctx: ModelContext, _ key: String) throws -> Prospect? {
        try ModelContext(ctx.container).fetch(FetchDescriptor<Prospect>()).first { $0.naturalKey == key }
    }

    // THE FAILED TURN. Written through the real `apply` (a re-list of the stored show plus one new show), with
    // the writes apply does not make written by hand in the same turn: a contact removed, a contact added,
    // a run URL appended, the source's dropped-show labels rewritten. Then apply's own save fails.
    private struct Turn { let outcome: ScoutService.Outcome; let writeSet: FailurePathRevert.WriteSet }

    private func failedTurn(_ ctx: ModelContext) throws -> Turn {
        let rondo = try #require(try held(ctx, Prospect.self).first { $0.naturalKey == "rondo-key" })
        let source = try #require(try held(ctx, WatchedSource.self).first)
        rondo.runSourceURLs.append("https://src-a.example/rondo/encore")
        rondo.recipients.removeAll { $0.id == "r2" }
        let fresh = Recipient(id: "r3", email: "three@rondo.example", provenance: .presenter)
        ctx.insert(fresh)
        rondo.recipients.append(fresh)
        source.lastDroppedShowLabelsRaw = "New Label\nAnother"
        let events = [
            ExtractedEvent(title: "Rondo Night", presenter: "Rondo Night", venue: Self.room,
                           performanceDate: Self.night, sourceUrl: Self.url),
            ExtractedEvent(title: "Brand New Recital", presenter: "Brand New Recital", venue: Self.room,
                           performanceDate: Self.night, sourceUrl: "https://src-a.example/new"),
        ]
        // Captured as the save begins, which is what A5's `willSave` observer records.
        let capture = FailurePathRevert.SaveCapture(ctx)
        let outcome = ScoutService.apply(events: events, clients: [], history: [], blocked: .empty,
                                         today: ScoutTestClock.beforeAllFixtures, sourceIds: ["src-a"], into: ctx)
        return Turn(outcome: outcome, writeSet: capture.set ?? .pending(in: ctx))
    }

    // MARK: the revert restores everything, relationships and archived blobs included

    @Test func aFailedSourceIsRevertedFieldForField() throws {
        let seeded = try seed("whole")
        defer { seeded.store.release() }
        let ctx = try seeded.store.openRefusing()
        let turn = try failedTurn(ctx)
        #expect(turn.outcome.saveFailed, "the store did not refuse the save, so nothing here failed")
        #expect(turn.outcome.updated >= 1 && turn.outcome.inserted >= 1, Comment(rawValue:
            "the source did not both touch the stored show and insert one: \(turn.outcome.updated) updated, "
            + "\(turn.outcome.inserted) inserted"))
        // After the failed save the context still holds what it carried; the revert depends on that.
        let after = FailurePathRevert.WriteSet.pending(in: ctx)
        #expect(after.changed.count == turn.writeSet.changed.count
                && after.inserted.count == turn.writeSet.inserted.count && after.changed.count >= 3, Comment(rawValue:
            "a failed save changed the pending set: \(turn.writeSet.count) at the save, \(after.count) after it"))
        // Before the revert the context differs from the store, so the equality below measures the revert.
        #expect(try Self.snapshot(ctx) != seeded.committed)

        let report = FailurePathRevert.revert(turn.writeSet, in: ctx)
        #expect(report.notRestorable.isEmpty, Comment(rawValue: "not restorable: \(report.notRestorable)"))
        #expect(report.insertsDeleted >= 2 && ctx.insertedModelsArray.isEmpty, Comment(rawValue:
            "inserts deleted: \(report.insertsDeleted), still inserted \(ctx.insertedModelsArray.count)"))

        // The instances the landing held read the committed values, which is what rollback() gets wrong.
        let rondo = try #require(try held(ctx, Prospect.self).first { $0.naturalKey == "rondo-key" })
        #expect(Set(rondo.recipients.map(\.id)) == ["r1", "r2"], Comment(rawValue:
            "the held show's contacts are \(rondo.recipients.map(\.id).sorted())"))
        #expect(rondo.runSourceURLs == [Self.url], Comment(rawValue: "the held run URLs are \(rondo.runSourceURLs)"))
        #expect(try held(ctx, WatchedSource.self).first?.lastDroppedShowLabelsRaw == "Old Label")
        let now = try Self.snapshot(ctx)
        #expect(now == seeded.committed, Comment(rawValue:
            "after the revert the context differs from the store: " + Self.differences(now, seeded.committed)))
    }

    // The to-many branch on its own. In the whole-record case above the contact's own to-one (`prospect`) is in
    // the write set too, and restoring it puts the contact back on the show through the inverse, so that case
    // stays green with the to-many branch broken (measured by mutation). Here only the SHOW is in the write set,
    // so nothing but the to-many branch can give it its contacts back.
    @Test func theToManyBranchRestoresAShowsContactsOnItsOwn() throws {
        let seeded = try seed("to-many")
        defer { seeded.store.release() }
        let ctx = try seeded.store.openRefusing()
        let rondo = try #require(try held(ctx, Prospect.self).first { $0.naturalKey == "rondo-key" })
        rondo.recipients.removeAll { $0.id == "r2" }
        #expect(Set(rondo.recipients.map(\.id)) == ["r1"])
        let report = FailurePathRevert.revert(.init(changed: [rondo], inserted: [], deleted: []), in: ctx)
        #expect(report.notRestorable.isEmpty && Set(rondo.recipients.map(\.id)) == ["r1", "r2"], Comment(rawValue:
            "the show's contacts after reverting the show alone: \(rondo.recipients.map(\.id).sorted()), \(report)"))
    }

    // MARK: the four correctness cases

    // (1) A pending pre-landing edit on the row the failed source also touches. With the entry flush it was
    // saved first, so it is committed and the revert keeps it. Without it the revert takes it back to the
    // committed value: THAT is the seen-to-fail the plan asks for, asserted here so it stays seen.
    @Test(arguments: [true, false])
    func aPendingEditOnTheTouchedRowSurvivesOnlyBecauseOfTheEntryFlush(flushed: Bool) throws {
        let edit: (ModelContext) throws -> Void = { ctx in
            let row = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first { $0.naturalKey == "rondo-key" })
            row.status = .queued
        }
        let seeded = try seed("edit-\(flushed)", flushed: flushed ? edit : { _ in })
        defer { seeded.store.release() }
        let ctx = try seeded.store.openRefusing()
        if !flushed { try edit(ctx) }
        let turn = try failedTurn(ctx)
        #expect(turn.outcome.saveFailed && turn.outcome.updated >= 1)
        let report = FailurePathRevert.revert(turn.writeSet, in: ctx)
        #expect(report.notRestorable.isEmpty)
        let status = try held(ctx, Prospect.self).first { $0.naturalKey == "rondo-key" }?.status
        let committedStatus = try committedRow(ctx, "rondo-key")?.status
        if flushed {
            #expect(status == .queued && committedStatus == .queued, Comment(rawValue:
                "a flushed edit did not survive the revert: \(String(describing: status))"))
            let now = try Self.snapshot(ctx)
            #expect(now == seeded.committed, Comment(rawValue:
                "after the revert the context differs from the store: " + Self.differences(now, seeded.committed)))
        } else {
            #expect(status != .queued, "without the entry flush the revert was expected to take the edit back")
        }
    }

    // (2) A #4325-style pending `missedScoutCount` increment on a row a later source matches. Same shape.
    @Test(arguments: [true, false])
    func aPendingMissedScoutIncrementSurvivesOnlyBecauseOfTheEntryFlush(flushed: Bool) throws {
        let increment: (ModelContext) throws -> Void = { ctx in
            let row = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first { $0.naturalKey == "rondo-key" })
            row.missedScoutCount += 1
        }
        let seeded = try seed("missed-\(flushed)", flushed: flushed ? increment : { _ in })
        defer { seeded.store.release() }
        let ctx = try seeded.store.openRefusing()
        if !flushed { try increment(ctx) }
        let turn = try failedTurn(ctx)
        #expect(turn.outcome.saveFailed && turn.outcome.updated >= 1)
        _ = FailurePathRevert.revert(turn.writeSet, in: ctx)
        let missed = try held(ctx, Prospect.self).first { $0.naturalKey == "rondo-key" }?.missedScoutCount
        #expect(missed == (flushed ? 1 : 0), Comment(rawValue:
            "flushed \(flushed): the increment reads \(String(describing: missed)) after the revert"))
    }

    // (3) An unrelated pending edit, on a row the failed source never touches. Same shape: it is in the pending
    // set at the failed save unless the entry flush saved it first.
    @Test(arguments: [true, false])
    func anUnrelatedPendingEditSurvivesOnlyBecauseOfTheEntryFlush(flushed: Bool) throws {
        let edit: (ModelContext) throws -> Void = { ctx in
            let row = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first { $0.naturalKey == "elsewhere-key" })
            row.status = .queued
        }
        let seeded = try seed("unrelated-\(flushed)", flushed: flushed ? edit : { _ in })
        defer { seeded.store.release() }
        let ctx = try seeded.store.openRefusing()
        if !flushed { try edit(ctx) }
        let turn = try failedTurn(ctx)
        #expect(turn.outcome.saveFailed)
        _ = FailurePathRevert.revert(turn.writeSet, in: ctx)
        let status = try held(ctx, Prospect.self).first { $0.naturalKey == "elsewhere-key" }?.status
        #expect((status == .queued) == flushed, Comment(rawValue:
            "flushed \(flushed): the unrelated edit reads \(String(describing: status)) after the revert"))
    }

    // (4) A failed CLOSING save, reverted over the closing save's write set, leaves `missedScoutCount` at its
    // committed value, so a recovery that re-runs the reconcile moves it exactly once. The reconcile's write is
    // made by hand here (the increment #4325 describes); the recovery is the same increment, which is what the
    // recovery's save would then carry. Without the revert the count moves twice, the double apply A12 warns
    // of, and that arm asserts it.
    @Test(arguments: [true, false])
    func aFailedClosingSaveRevertedLeavesTheMissCountToMoveExactlyOnce(reverted: Bool) throws {
        let seeded = try seed("closing-\(reverted)")
        defer { seeded.store.release() }
        let ctx = try seeded.store.openRefusing()
        let rondo = try #require(try held(ctx, Prospect.self).first { $0.naturalKey == "rondo-key" })
        rondo.missedScoutCount += 1
        let source = try #require(try held(ctx, WatchedSource.self).first)
        source.lastCheckedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let closing = FailurePathRevert.WriteSet.pending(in: ctx)
        #expect(throws: (any Error).self, "the closing save was expected to fail") { try ctx.save() }
        if reverted {
            let report = FailurePathRevert.revert(closing, in: ctx)
            #expect(report.notRestorable.isEmpty && rondo.missedScoutCount == 0, Comment(rawValue:
                "the held row reads \(rondo.missedScoutCount) after the revert: \(report)"))
        }
        // Recovery: the reconcile runs once more.
        rondo.missedScoutCount += 1
        #expect(try committedRow(ctx, "rondo-key")?.missedScoutCount == 0)
        #expect(rondo.missedScoutCount == (reverted ? 1 : 2), Comment(rawValue:
            "reverted \(reverted): recovery would save a miss count of \(rondo.missedScoutCount)"))
    }

    // MARK: what (ii) cannot restore

    // A committed row the failed turn DELETED. SwiftData has no undelete short of rollback(), so the revert
    // must say so rather than skip it. Nothing on the landing path deletes a committed row today; A5 must keep
    // that true or solve this first.
    @Test func aDeletedCommittedRowIsReportedNotRestorable() throws {
        let seeded = try seed("deleted")
        defer { seeded.store.release() }
        let ctx = try seeded.store.openRefusing()
        let gone = try #require(try held(ctx, Prospect.self).first { $0.naturalKey == "elsewhere-key" })
        ctx.delete(gone)
        let set = FailurePathRevert.WriteSet.pending(in: ctx)
        #expect(throws: (any Error).self) { try ctx.save() }
        let report = FailurePathRevert.revert(set, in: ctx)
        #expect(report.notRestorable.count == 1, Comment(rawValue: "not restorable: \(report.notRestorable)"))
        #expect(try Self.snapshot(ctx) != seeded.committed, "the deleted row came back, which (ii) cannot do")
    }

    // MARK: the cost, on the hardest real source at 4x (opt in)

    // TEST_RUNNER_MEASURE_4275=1 TEST_RUNNER_MEASURE_4327_REVERT=1 mac/scripts/run-tests-locked.sh \
    //   -only-testing:OvertureTests/FailurePathRevertProbeTests
    //
    // Lands ONE real source (the one with the most recorded events, or TEST_RUNNER_MEASURE_4327_REVERT_SOURCE
    // by position) on a 4x scaled clone whose file refuses saves, captures what the failed save carried, and
    // times the revert. Three rounds, each landing the source again onto the reverted context. Each round also
    // counts the reverted shows whose fields differ from a fresh read of the store, which must be zero.
    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func revertCostOnTheHardestSourceAt4x() async throws {
        guard LandingProbe.enabled, LandingProbe.env["MEASURE_4327_REVERT"] != nil else {
            print("probe4327: revert not measured. Set TEST_RUNNER_MEASURE_4275=1 TEST_RUNNER_MEASURE_4327_REVERT=1.")
            return
        }
        let handoff = StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
        let inputsDir = try sandboxes.make(named: "probe4327-revert-inputs")
        func copied(_ name: String) -> URL {
            let to = inputsDir.appendingPathComponent(name)
            try? FileManager.default.copyItem(at: handoff.appendingPathComponent(name), to: to)
            return to
        }
        let resultsCopy = copied("overture-scout-extract-results.json")
        let exportCopy = copied("downbeat-export.json")
        let historyCopy = copied("overture-history.json")
        guard let data = try? Data(contentsOf: resultsCopy),
              let results = try? ScoutExtractResultsDecoder.decode(data), !results.results.isEmpty else {
            LandingProbe.say("revert UNMEASURED: no readable scout extract results on this machine")
            return
        }
        let chosen = Int(LandingProbe.env["MEASURE_4327_REVERT_SOURCE"] ?? "").map { $0 - 1 }
            ?? results.results.indices.max { results.results[$0].events.count < results.results[$1].events.count }!
        guard results.results.indices.contains(chosen) else {
            LandingProbe.say("revert UNMEASURED: TEST_RUNNER_MEASURE_4327_REVERT_SOURCE names source \(chosen + 1), "
                             + "and the results file has \(results.results.count)")
            return
        }
        let one = ScoutExtractResults(version: results.version, generatedAt: results.generatedAt,
                                      results: [results.results[chosen]])
        let dir = try sandboxes.make(named: "probe4327-revert-stores")
        guard let base = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let url = try Phase0.scaledCopy(of: base, factor: 4, in: dir)
        let loaded = DownbeatBridge.loadWithHealth(from: exportCopy, now: Date())
        let store = RefusingStore(url: url)
        defer { store.release() }
        let ctx = try store.openRefusing()
        let existing = try ctx.fetch(FetchDescriptor<Prospect>())
        let history = LocalHistory.forMatching(existing: existing, importedFrom: historyCopy)
        let blocked = ScoutService.blockedCalendar(export: (loaded.bookings, loaded.blockedDates, loaded.health),
                                                   context: ctx)
        LandingProbe.say("revert x4: \(existing.count) shows, source \(chosen + 1) of \(results.results.count) with "
                         + "\(results.results[chosen].events.count) recorded events, " + Phase0.load())
        var timings: [Double] = []
        for round in 1...3 {
            let wait = Phase0.waitForLoad(below: 8, deadline: 1800, poll: 5)
            let capture = FailurePathRevert.SaveCapture(ctx)
            let outcome = await ScoutExtractIngest.ingest(one, clients: loaded.clients, history: history,
                                                          blocked: blocked, into: ctx)
            let captured = capture.set
            // Everything pending now: the failed source save's set plus what ran after it (the reconcile),
            // which is the set a failed closing save would carry too.
            let set = FailurePathRevert.WriteSet.pending(in: ctx)
            var report = FailurePathRevert.Report()
            let ms = Phase0.time { report = FailurePathRevert.revert(set, in: ctx) }
            timings.append(ms)
            let fresh = ModelContext(ctx.container)
            var differing = 0
            for model in set.changed {
                guard let p = model as? Prospect else { continue }
                let id = p.persistentModelID
                var d = FetchDescriptor<Prospect>(predicate: #Predicate { $0.persistentModelID == id })
                d.fetchLimit = 1
                if let committed = try fresh.fetch(d).first, phase0Values(committed) != phase0Values(p) { differing += 1 }
            }
            LandingProbe.say("revert x4 round \(round): save failed \(outcome.saveFailed), set at the failed save "
                             + "\(captured?.count ?? -1) rows, pending after the turn \(set.changed.count) changed, "
                             + "\(set.inserted.count) inserted, \(set.deleted.count) deleted; revert "
                             + "\(LandingProbe.f1(ms)) ms: \(report); shows still differing from the store \(differing); "
                             + wait.text + ", " + Phase0.load())
        }
        LandingProbe.say("revert x4 median of \(timings.count): " + Phase0.Reading(runs: timings).text)
    }
}
