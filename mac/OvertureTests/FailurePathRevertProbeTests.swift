import Testing
import Foundation
import SQLite3
import SwiftData

// #4327 step 0.8: the failure path revert, candidate (ii) only (decision 2), and its correctness cases, each a
// test (L246, L574). The revert itself is `FailurePathRevert`, beside this file.
//
// THE FAILURE IS REAL, AND IT CAN BE SWITCHED OFF. Every failed save here is a genuine SwiftData save
// failure raised by the store: the store file carries SQLite triggers that abort any insert, update or delete
// on the show, contact and watched source tables while a one row switch table is set, so the source's own
// `ScoutService.apply` save throws and the source reports `saveFailed`. Clearing the switch, from a separate
// connection, is what lets "a LATER save succeeds" be asserted on the SAME context. The two cheaper ways were
// measured first and neither can do that: a duplicate natural key does not fail a save (SwiftData upserts
// it), and an immutable store file (`ImmutableStoreFixture`, #617) opens the connection read only for the
// container's whole life, so clearing its flags leaves every later save failing too.
//
// The entry flush (A3/A5) is modelled by what it does: the pre-landing edit is SAVED before the store starts
// refusing, so it is committed when the failed turn begins. Without the flush the same edit is made, unsaved,
// in the landing's own context.
//
// What each case asserts is read through a FRESH context after that later save, so it is what the store
// holds, and through the instance the landing already held, which is the thing `rollback()` gets wrong.
@MainActor
@Suite("The failure path revert restores what a failed save carried (#4327 step 0.8)", .serialized)
final class FailurePathRevertProbeTests {
    private let sandboxes = TemporarySandboxes()
    private static let room = "Merkin Hall"
    private static let night = "2099-10-01"
    private static let url = "https://src-a.example/rondo"

    // MARK: a store that refuses saves, and then stops refusing

    final class RefusingStore {
        enum Failure: Error { case sql(String) }
        let url: URL
        private(set) var container: ModelContainer?
        init(url: URL) { self.url = url }

        private func exec(_ sql: String) throws {
            var db: OpaquePointer?
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                sqlite3_close(db)
                throw Failure.sql("open failed")
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 5000)
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw Failure.sql(message)
            }
        }

        /// Installs the switch and its triggers, turns the refusal ON, and opens the container the landing
        /// runs on, autosave off.
        @MainActor func openRefusing() throws -> ModelContext {
            var sql = "CREATE TABLE IF NOT EXISTS PROBEREFUSE (on_ INTEGER);"
            for table in ["ZPROSPECT", "ZRECIPIENT", "ZWATCHEDSOURCE"] {
                for op in ["INSERT", "UPDATE", "DELETE"] {
                    sql += "CREATE TRIGGER IF NOT EXISTS PROBEREFUSE_\(table)_\(op) BEFORE \(op) ON \(table) "
                        + "WHEN EXISTS (SELECT 1 FROM PROBEREFUSE) BEGIN SELECT RAISE(ABORT, 'probe refuses'); END;"
                }
            }
            try exec(sql + "DELETE FROM PROBEREFUSE; INSERT INTO PROBEREFUSE VALUES (1);")
            let c = try ModelContainer(for: AppSchema.schema,
                                       configurations: [ModelConfiguration(schema: AppSchema.schema, url: url)])
            container = c
            c.mainContext.autosaveEnabled = false
            return c.mainContext
        }

        /// Turns the refusal off, so the next save is accepted.
        func allowSaves() {
            try? exec("DELETE FROM PROBEREFUSE;")
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
            let c = try ModelContainer(for: AppSchema.schema,
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
        let committed = try Self.snapshot(ModelContext(try ModelContainer(
            for: AppSchema.schema, configurations: [ModelConfiguration(schema: AppSchema.schema, url: url)])))
        return Seeded(store: RefusingStore(url: url), committed: committed)
    }

    // Every stored field of every show, contact and watched source, keyed by identity, relationships as the
    // sorted identities of their members. Read through whatever context is passed.
    static func snapshot(_ ctx: ModelContext) throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        func render(_ value: Any?) -> String {
            guard let value else { return "nil" }
            if let members = value as? any RevertModelArray {
                return members.memberIDs.map { "\($0)" }.sorted().joined(separator: ",")
            }
            if let member = value as? any RevertOptionalModel { return member.memberID.map { "\($0)" } ?? "nil" }
            if let model = value as? any PersistentModel { return "\(model.persistentModelID)" }
            return String(describing: value)
        }
        func add<M: ScopeObserved>(_: M.Type) throws {
            for row in try ctx.fetch(FetchDescriptor<M>()) {
                out["\(M.self) \(row.persistentModelID)"] = M.scopeFields.map { render(row[keyPath: $0.keyPath]) }
            }
        }
        try add(Prospect.self)
        try add(Recipient.self)
        try add(WatchedSource.self)
        return out
    }

    private func held<M: PersistentModel>(_ ctx: ModelContext, _: M.Type) throws -> [M] {
        try ctx.fetch(FetchDescriptor<M>())
    }

    // THE FAILED TURN. Written through the real `apply` (a re-list of the stored show plus one new show), with
    // the writes apply does not make written by hand in the same turn: a contact removed, a contact added,
    // a run URL appended, the source's archived dropped-show labels rewritten. Then apply's own save fails.
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

    @Test func aFailedSourceIsRevertedFieldForFieldAndALaterSaveSucceeds() throws {
        let seeded = try seed("whole")
        defer { seeded.store.allowSaves() }
        let ctx = try seeded.store.openRefusing()
        let turn = try failedTurn(ctx)
        #expect(turn.outcome.saveFailed, "the store did not refuse the save, so nothing here failed")
        #expect(turn.outcome.updated + turn.outcome.inserted >= 2, Comment(rawValue:
            "the source did not both touch the stored show and insert one: \(turn.outcome.updated) updated, "
            + "\(turn.outcome.inserted) inserted"))
        // After the failed save the context still holds what it carried; the revert depends on that.
        let after = FailurePathRevert.WriteSet.pending(in: ctx)
        #expect(after.changed.count == turn.writeSet.changed.count
                && after.inserted.count == turn.writeSet.inserted.count, Comment(rawValue:
            "a failed save changed the pending set: \(turn.writeSet.count) at the save, \(after.count) after it"))

        let report = FailurePathRevert.revert(turn.writeSet, in: ctx)
        #expect(report.notRestorable.isEmpty, Comment(rawValue: "not restorable: \(report.notRestorable)"))
        #expect(report.insertsDeleted >= 2, Comment(rawValue: "inserts deleted: \(report.insertsDeleted)"))

        // The instances the landing held read the committed values, which is what rollback() gets wrong.
        let rondo = try #require(try held(ctx, Prospect.self).first { $0.naturalKey == "rondo-key" })
        #expect(Set(rondo.recipients.map(\.id)) == ["r1", "r2"], Comment(rawValue:
            "the held show's contacts are \(rondo.recipients.map(\.id).sorted())"))
        #expect(rondo.runSourceURLs == [Self.url], Comment(rawValue: "the held run URLs are \(rondo.runSourceURLs)"))
        #expect(try held(ctx, WatchedSource.self).first?.lastDroppedShowLabelsRaw == "Old Label")

        seeded.store.allowSaves()
        try ctx.save()
        let now = try Self.snapshot(ModelContext(ctx.container))
        #expect(now == seeded.committed, Comment(rawValue:
            "after the revert and a later save the store differs from before the turn in "
            + "\(Set(now.keys).symmetricDifference(seeded.committed.keys).count) rows present and "
            + "\(now.filter { seeded.committed[$0.key] != nil && seeded.committed[$0.key] != $0.value }.count) rows' fields"))
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
        defer { seeded.store.allowSaves() }
        let ctx = try seeded.store.openRefusing()
        if !flushed { try edit(ctx) }
        let turn = try failedTurn(ctx)
        #expect(turn.outcome.saveFailed && turn.outcome.updated >= 1)
        let report = FailurePathRevert.revert(turn.writeSet, in: ctx)
        #expect(report.notRestorable.isEmpty)
        seeded.store.allowSaves()
        try ctx.save()
        let status = try ModelContext(ctx.container).fetch(FetchDescriptor<Prospect>())
            .first { $0.naturalKey == "rondo-key" }?.status
        if flushed {
            #expect(status == .queued, Comment(rawValue: "a flushed edit did not survive the revert: \(String(describing: status))"))
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
        defer { seeded.store.allowSaves() }
        let ctx = try seeded.store.openRefusing()
        if !flushed { try increment(ctx) }
        let turn = try failedTurn(ctx)
        #expect(turn.outcome.saveFailed && turn.outcome.updated >= 1)
        _ = FailurePathRevert.revert(turn.writeSet, in: ctx)
        seeded.store.allowSaves()
        try ctx.save()
        let missed = try ModelContext(ctx.container).fetch(FetchDescriptor<Prospect>())
            .first { $0.naturalKey == "rondo-key" }?.missedScoutCount
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
        defer { seeded.store.allowSaves() }
        let ctx = try seeded.store.openRefusing()
        if !flushed { try edit(ctx) }
        let turn = try failedTurn(ctx)
        #expect(turn.outcome.saveFailed)
        _ = FailurePathRevert.revert(turn.writeSet, in: ctx)
        seeded.store.allowSaves()
        try ctx.save()
        let status = try ModelContext(ctx.container).fetch(FetchDescriptor<Prospect>())
            .first { $0.naturalKey == "elsewhere-key" }?.status
        #expect((status == .queued) == flushed, Comment(rawValue:
            "flushed \(flushed): the unrelated edit reads \(String(describing: status)) after the revert"))
    }

    // (4) A failed CLOSING save, reverted over the closing save's write set, leaves `missedScoutCount` at its
    // committed value, so a recovery that re-runs the reconcile moves it exactly once. The reconcile's write is
    // made by hand here (the increment #4325 describes); the recovery is the same increment, saved. Without
    // the revert the count moves twice, which is the double apply A12 warns of, and that arm asserts it.
    @Test(arguments: [true, false])
    func aFailedClosingSaveRevertedLeavesTheMissCountToMoveExactlyOnce(reverted: Bool) throws {
        let seeded = try seed("closing-\(reverted)")
        defer { seeded.store.allowSaves() }
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
        // Recovery: the store accepts saves again and the reconcile runs once more.
        seeded.store.allowSaves()
        rondo.missedScoutCount += 1
        try ctx.save()
        let missed = try ModelContext(ctx.container).fetch(FetchDescriptor<Prospect>())
            .first { $0.naturalKey == "rondo-key" }?.missedScoutCount
        #expect(missed == (reverted ? 1 : 2), Comment(rawValue:
            "reverted \(reverted): the miss count is \(String(describing: missed)) after recovery"))
    }

    // MARK: what (ii) cannot restore

    // A committed row the failed turn DELETED. SwiftData has no undelete short of rollback(), so the revert
    // must say so rather than skip it. Nothing on the landing path deletes a committed row today; A5 must keep
    // that true or solve this first.
    @Test func aDeletedCommittedRowIsReportedNotRestorable() throws {
        let seeded = try seed("deleted")
        defer { seeded.store.allowSaves() }
        let ctx = try seeded.store.openRefusing()
        let gone = try #require(try held(ctx, Prospect.self).first { $0.naturalKey == "elsewhere-key" })
        ctx.delete(gone)
        let set = FailurePathRevert.WriteSet.pending(in: ctx)
        #expect(throws: (any Error).self) { try ctx.save() }
        let report = FailurePathRevert.revert(set, in: ctx)
        #expect(report.notRestorable.count == 1, Comment(rawValue: "not restorable: \(report.notRestorable)"))
    }

    // MARK: the cost, on the hardest real source at 4x (opt in)

    // TEST_RUNNER_MEASURE_4275=1 TEST_RUNNER_MEASURE_4327_REVERT=1 mac/scripts/run-tests-locked.sh \
    //   -only-testing:OvertureTests/FailurePathRevertProbeTests
    //
    // Lands ONE real source (the one with the most recorded events, or TEST_RUNNER_MEASURE_4327_REVERT_SOURCE
    // by position) on a 4x scaled clone whose file refuses saves, captures what the failed save carried, and
    // times the revert. Three rounds, each landing the source again onto the reverted context. Each round also
    // counts the reverted rows whose fields differ from a fresh read of the store, which must be zero.
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
        let one = ScoutExtractResults(version: results.version, generatedAt: results.generatedAt,
                                      results: [results.results[chosen]])
        let dir = try sandboxes.make(named: "probe4327-revert-stores")
        guard let base = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let url = try Phase0.scaledCopy(of: base, factor: 4, in: dir)
        let loaded = DownbeatBridge.loadWithHealth(from: exportCopy, now: Date())
        let store = RefusingStore(url: url)
        defer { store.allowSaves() }
        let ctx = try store.openRefusing()
        let existing = try ctx.fetch(FetchDescriptor<Prospect>())
        let history = LocalHistory.forMatching(existing: existing, importedFrom: historyCopy)
        let blocked = ScoutService.blockedCalendar(export: (loaded.bookings, loaded.blockedDates, loaded.health),
                                                   context: ctx)
        LandingProbe.say("revert x4: \(existing.count) shows, source \(chosen + 1) of \(results.results.count) with "
                         + "\(results.results[chosen].events.count) recorded events, " + Phase0.load())
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
    }
}
