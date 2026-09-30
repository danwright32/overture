import Testing
import Foundation
import SwiftData

// #4327 step 0.4: is an inserted row's `persistentModelID` the same before and after its first save?
//
// WHY IT IS ASKED. Plan D4 (discussion #4326, revision 5) re-keys the landing's working set by
// `persistentModelID`. If a freshly inserted row's identifier changes when it is saved, a working set keyed
// on it loses every row the landing inserted at the first per-source save, and D4 has to remap temporary
// identifiers to permanent ones in the `willSave` and `didSave` pair. This says which, and it also says
// whether that remap is possible at all: whether the object `willSave` names still carries the temporary
// identifier, and whether `didSave` (posted synchronously on the saving thread) already sees the permanent
// one on the same object.
//
// WHAT WAS ALREADY KNOWN. #4106's probe 2 (`QueueEnginePhase0ProbeTests.probe2DidSaveAndObservation`) pinned
// "an identifier captured before the first save no longer resolves after it" on 2026-09-26, on an ON DISK
// scratch store, and only when `TEST_RUNNER_MEASURE_4106_PHASE0` is set, so nothing ran it on an ordinary
// push. This asks the same question on BOTH store kinds the app and its tests use, answers the two D4
// sub-questions that probe did not, and runs on every push, so an SDK that changes the answer turns this
// red instead of silently breaking D4 (L1).
//
// A POSITIVE CONTROL in the same fixture (L159): a row that was ALREADY saved keeps its identifier across a
// second save that edits it. Without it, "the identifier changed" could be a comparison that never reads
// equal.
@MainActor
@Suite("An inserted row's persistentModelID across its first save (#4327 step 0.4)")
final class InsertedRowIdentifierAcrossSaveTests {

    private let sandboxes = TemporarySandboxes()

    // Posted synchronously by `save()` on the saving thread, which for the main context is this actor.
    // Each notification's reading is taken INSIDE the observer, because that is where D4's remap would run.
    // Unchecked because the observers only ever run on the main thread (asserted by `assumeIsolated`), which
    // is where every read of these fields happens too.
    private final class SaveWatch: @unchecked Sendable {
        var willSaveInserted: [(object: ObjectIdentifier, id: PersistentIdentifier)] = []
        var didSaveInserted: [PersistentIdentifier] = []
        var objectIDInsideDidSave: PersistentIdentifier?
        private var tokens: [NSObjectProtocol] = []

        init(_ ctx: ModelContext, watching row: Prospect) {
            let center = NotificationCenter.default
            nonisolated(unsafe) let context = ctx
            nonisolated(unsafe) let watched = row
            tokens.append(center.addObserver(forName: ModelContext.willSave, object: ctx, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.willSaveInserted = context.insertedModelsArray.map { (ObjectIdentifier($0), $0.persistentModelID) }
                }
            })
            tokens.append(center.addObserver(forName: ModelContext.didSave, object: ctx, queue: nil) { [weak self] note in
                let inserted = note.userInfo?[ModelContext.NotificationKey.insertedIdentifiers.rawValue]
                    as? [PersistentIdentifier] ?? []
                MainActor.assumeIsolated {
                    self?.didSaveInserted = inserted
                    self?.objectIDInsideDidSave = watched.persistentModelID
                }
            })
        }

        func stop() { tokens.forEach(NotificationCenter.default.removeObserver) }
    }

    private static func show(_ key: String) -> Prospect {
        Prospect(naturalKey: key, groupName: "Probe Ensemble", discipline: "music", venue: "Probe Hall",
                 performanceDate: "2027-04-01", sourceListingURL: nil, priorRelationship: "none",
                 production: "presenter", profile: "strong", coverage: "likely_uncovered", fitScore: 5,
                 tier: "mid", fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                 possibleMatchName: nil, status: .new)
    }

    private struct Reading: CustomStringConvertible {
        let store: String
        let changedOnFirstSave: Bool
        let temporaryHadNoStore: Bool
        let permanentHasStore: Bool
        let willSaveSawTemporary: Bool
        let didSaveNamedPermanent: Bool
        let didSaveNamedTemporary: Bool
        let objectAlreadyPermanentInsideDidSave: Bool
        let temporaryResolvesViaModelFor: Bool
        let temporaryResolvesViaRegistered: Bool
        let temporaryFetchRows: Int
        let permanentFetchIsSameObject: Bool
        let savedRowKeptItsID: Bool

        var description: String {
            "\(store): identifier changed on first save \(changedOnFirstSave); temporary carries no store "
                + "identifier \(temporaryHadNoStore), permanent carries one \(permanentHasStore); willSave's "
                + "inserted object still holds the temporary id \(willSaveSawTemporary); didSave's "
                + "insertedIdentifiers names the permanent id \(didSaveNamedPermanent), the temporary id "
                + "\(didSaveNamedTemporary); the object reads the permanent id inside didSave "
                + "\(objectAlreadyPermanentInsideDidSave); after the save the temporary id resolves via "
                + "model(for:) to the same object \(temporaryResolvesViaModelFor), via registeredModel "
                + "\(temporaryResolvesViaRegistered), via a fetch \(temporaryFetchRows) rows; a fetch by the "
                + "permanent id returns the same object \(permanentFetchIsSameObject); CONTROL an already "
                + "saved row keeps its id across a second save \(savedRowKeptItsID)"
        }
    }

    private func read(_ store: String, _ container: ModelContainer) throws -> Reading {
        let ctx = container.mainContext

        // The control row, saved first so its identifier is already permanent.
        let settled = Self.show("probe-settled")
        ctx.insert(settled)
        try ctx.save()
        let settledBefore = settled.persistentModelID
        settled.fitReason = "edited"
        try ctx.save()
        let savedRowKeptItsID = settled.persistentModelID == settledBefore

        let row = Self.show("probe-inserted")
        ctx.insert(row)
        let before = row.persistentModelID
        let watch = SaveWatch(ctx, watching: row)
        defer { watch.stop() }
        try ctx.save()
        let after = row.persistentModelID

        let viaModel = ctx.model(for: before) as? Prospect
        let viaRegistered: Prospect? = ctx.registeredModel(for: before)
        let viaTemporary = try ctx.fetch(FetchDescriptor<Prospect>(
            predicate: #Predicate { $0.persistentModelID == before }))
        let viaPermanent = try ctx.fetch(FetchDescriptor<Prospect>(
            predicate: #Predicate { $0.persistentModelID == after }))

        return Reading(
            store: store,
            changedOnFirstSave: before != after,
            temporaryHadNoStore: before.storeIdentifier == nil,
            permanentHasStore: after.storeIdentifier != nil,
            willSaveSawTemporary: watch.willSaveInserted.contains { $0.object == ObjectIdentifier(row) && $0.id == before },
            didSaveNamedPermanent: watch.didSaveInserted.contains(after),
            didSaveNamedTemporary: watch.didSaveInserted.contains(before),
            objectAlreadyPermanentInsideDidSave: watch.objectIDInsideDidSave == after,
            temporaryResolvesViaModelFor: viaModel === row,
            temporaryResolvesViaRegistered: viaRegistered === row,
            temporaryFetchRows: viaTemporary.count,
            permanentFetchIsSameObject: viaPermanent.count == 1 && viaPermanent.first === row,
            savedRowKeptItsID: savedRowKeptItsID)
    }

    // Through the one helper, so autosave is OFF on both: a timer save landing between the insert and the
    // explicit save would change what `before` and `willSave` see (#3874, L613).
    private func inMemory() throws -> ModelContainer {
        try TestModelContainer.inMemory(AppSchema.models)
    }

    private func onDisk() throws -> ModelContainer {
        let dir = try sandboxes.make(named: "inserted-row-identifier")
        return try TestModelContainer.onDisk(AppSchema.models, at: dir.appendingPathComponent("probe.store"))
    }

    @Test(arguments: ["in memory", "on disk"])
    func anInsertedRowsIdentifierAcrossItsFirstSave(_ kind: String) throws {
        let container = try kind == "in memory" ? inMemory() : onDisk()
        let r = try read(kind, container)
        print("step-0.4 " + r.description)

        // The control first: a comparison that can read "same" is what makes "changed" a finding (L159).
        #expect(r.savedRowKeptItsID, Comment(rawValue: "an already saved row's identifier moved on a second save, so this "
                + "harness cannot tell a changed identifier from an unstable one"))

        // PINNED 2026-09-29, both store kinds. D4's working set cannot key an inserted row on the identifier
        // it had before its first save: the identifier CHANGES, the old one stops resolving, and the remap
        // D4 describes is possible because willSave still sees the temporary id on the object and the object
        // already reads the permanent one inside the synchronous didSave.
        #expect(r.changedOnFirstSave, "PINNED 2026-09-29: an inserted row's identifier changes on its first save")
        #expect(r.willSaveSawTemporary && r.objectAlreadyPermanentInsideDidSave && r.didSaveNamedPermanent
                && !r.didSaveNamedTemporary, Comment(rawValue: "PINNED 2026-09-29: willSave sees the temporary id, didSave names only the permanent one, "
                + "and the object already reads it inside didSave, so a remap in that pair is possible"))
        #expect(!r.temporaryResolvesViaRegistered && r.temporaryFetchRows == 0 && r.permanentFetchIsSameObject, Comment(rawValue: "PINNED 2026-09-29: after the save the temporary id is not registered and fetches nothing, "
                + "while the permanent id fetches the very same object"))
    }
}
