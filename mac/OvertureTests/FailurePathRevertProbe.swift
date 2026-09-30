import Foundation
import SwiftData

// #4327 step 0.8: the failure path revert, candidate (ii) of decision 2, BUILT FOR REAL so its correctness
// cases and its cost are measured rather than argued (L246, L574). A PROBE: it lives in the test target, and
// nothing in the app calls it. A5 is where a revert ships, and it ships only if every case below holds.
//
// WHAT IT DOES. A save failed, and the context still holds everything that save was carrying (the write set,
// captured as the save began). For every CHANGED row in that set it reads the row's COMMITTED values through a
// fresh `ModelContext` on the same container, found by `persistentModelID`, and copies a value back only for a
// field whose committed value differs. For every INSERTED row it deletes the row, which for a row never saved
// just takes it back out of the context. Relationships are copied as the committed members' identities,
// resolved into the context being reverted, so a to-many (`Prospect.recipients`) gets back exactly the rows it
// had. The field list is every model's `scopeFields`, which `ScopeFieldsMatchTheSchemaTests` holds to the
// schema, so a stored property added later is reverted without anybody remembering to list it (L41, L96).
//
// WHAT IT CANNOT DO, said plainly rather than left for somebody to find (L11). A committed row the failed
// turn DELETED cannot be brought back: SwiftData offers no undelete short of `rollback()`, which is banned
// here because it does not restore instances already fetched (the plan's overruled dissent). Such a row is
// reported in `notRestorable`, never silently skipped. Nothing on the landing path deletes a committed row
// today (`ScoutLandingStore`, "Nothing in the landing deletes a show today"), so A5 must keep that true or
// solve this first.
//
// It restores COMMITTED values, which equal the values just before the failed turn only if nothing the revert
// touches was pending before that turn began. That is what the plan's entry flush (A3/A5) guarantees, and the
// correctness tests show both halves: with the flush a pending edit survives, without it the edit is reverted.
@MainActor
enum FailurePathRevert {
    /// What a save was carrying, taken from the context before (or as) it saved.
    struct WriteSet {
        var changed: [any PersistentModel]
        var inserted: [any PersistentModel]
        var deleted: [any PersistentModel]

        static func pending(in context: ModelContext) -> WriteSet {
            WriteSet(changed: context.changedModelsArray, inserted: context.insertedModelsArray,
                     deleted: context.deletedModelsArray)
        }

        var count: Int { changed.count + inserted.count + deleted.count }
    }

    /// The pending set as the FIRST save after this is made begins, which is the write set a failed save
    /// carried: what A5's `willSave` observer would record. Held for as long as the capture is.
    final class SaveCapture: @unchecked Sendable {
        private(set) var set: WriteSet?
        private var token: NSObjectProtocol?

        init(_ context: ModelContext) {
            token = NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: context,
                                                           queue: nil) { [weak self] note in
                // Posted synchronously by `save()` on the saving thread, which for these contexts is the main
                // actor, so the context never crosses an isolation boundary.
                nonisolated(unsafe) let saving = note.object as? ModelContext
                MainActor.assumeIsolated {
                    guard let self, self.set == nil, let saving else { return }
                    self.set = .pending(in: saving)
                }
            }
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }

    struct Report: CustomStringConvertible {
        var rowsRead = 0
        var fieldsCompared = 0
        var fieldsWritten = 0
        // Fields whose value type offers no equality, so they were written back without a comparison. Zero
        // on today's schema; counted so a type that stops being comparable is seen rather than assumed.
        var fieldsWrittenUncompared = 0
        var insertsDeleted = 0
        var notRestorable: [String] = []

        var description: String {
            "rows read \(rowsRead), fields compared \(fieldsCompared), fields written back \(fieldsWritten) "
                + "(\(fieldsWrittenUncompared) without a comparison), inserts deleted \(insertsDeleted), "
                + "not restorable \(notRestorable.count)"
        }
    }

    /// Reverts `set` in `context` to the committed values. Never calls `rollback()`.
    static func revert(_ set: WriteSet, in context: ModelContext) -> Report {
        var report = Report()
        let committed = ModelContext(context.container)
        committed.autosaveEnabled = false
        let insertedIDs = Set(set.inserted.map(\.persistentModelID))
        for model in set.changed where !insertedIDs.contains(model.persistentModelID) {
            guard let row = model as? any ScopeObserved else {
                report.notRestorable.append("\(type(of: model)): not a ScopeObserved model, so no field list")
                continue
            }
            revertRow(row, from: committed, into: context, report: &report)
        }
        for model in set.deleted where !insertedIDs.contains(model.persistentModelID) {
            report.notRestorable.append("\(type(of: model)): a committed row deleted by the failed turn")
        }
        for model in set.inserted {
            context.delete(model)
            report.insertsDeleted += 1
        }
        return report
    }

    private static func revertRow<M: ScopeObserved>(_ row: M, from committed: ModelContext, into context: ModelContext,
                                                   report: inout Report) {
        let id = row.persistentModelID
        var descriptor = FetchDescriptor<M>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        guard let base = (try? committed.fetch(descriptor))?.first else {
            report.notRestorable.append("\(M.self): its committed row could not be read")
            return
        }
        report.rowsRead += 1
        for field in M.scopeFields {
            guard let path = field.keyPath as? any RevertibleField else {
                report.notRestorable.append("\(M.self): a field whose key path is not writable")
                continue
            }
            switch path.revert(from: base, to: row, resolvingIn: context) {
            case .same: report.fieldsCompared += 1
            case .written: report.fieldsCompared += 1; report.fieldsWritten += 1
            case .writtenUncompared: report.fieldsWrittenUncompared += 1; report.fieldsWritten += 1
            case .unresolvable(let why): report.notRestorable.append("\(M.self): \(why)")
            }
        }
    }
}

enum RevertStep { case same, written, writtenUncompared, unresolvable(String) }

/// A key path whose committed value can be copied onto the row being reverted.
protocol RevertibleField {
    @MainActor func revert(from committed: Any, to row: Any, resolvingIn context: ModelContext) -> RevertStep
}

/// A to-many relationship's value, so its members can be compared and resolved by identity.
protocol RevertModelArray {
    var memberIDs: [PersistentIdentifier] { get }
    static func resolving(_ ids: [PersistentIdentifier], in context: ModelContext) -> Self?
}

extension Array: RevertModelArray where Element: PersistentModel {
    var memberIDs: [PersistentIdentifier] { map(\.persistentModelID) }
    static func resolving(_ ids: [PersistentIdentifier], in context: ModelContext) -> Self? {
        let resolved = ids.compactMap { context.model(for: $0) as? Element }
        return resolved.count == ids.count ? resolved : nil
    }
}

/// A to-one relationship's value, so it can be compared and resolved by identity.
protocol RevertOptionalModel {
    var memberID: PersistentIdentifier? { get }
    static func resolving(_ id: PersistentIdentifier?, in context: ModelContext) -> Self?
}

extension Optional: RevertOptionalModel where Wrapped: PersistentModel {
    var memberID: PersistentIdentifier? { self?.persistentModelID }
    static func resolving(_ id: PersistentIdentifier?, in context: ModelContext) -> Self? {
        guard let id else { return .some(.none) }
        guard let model = context.model(for: id) as? Wrapped else { return nil }
        return .some(model)
    }
}

extension Equatable {
    fileprivate func revertEquals(_ other: Any) -> Bool {
        guard let other = other as? Self else { return false }
        return self == other
    }
}

extension ReferenceWritableKeyPath: RevertibleField {
    @MainActor func revert(from committed: Any, to row: Any, resolvingIn context: ModelContext) -> RevertStep {
        guard let base = committed as? Root, let row = row as? Root else { return .unresolvable("wrong root") }
        let was = base[keyPath: self]
        let now = row[keyPath: self]
        if let wasMembers = was as? any RevertModelArray, let nowMembers = now as? any RevertModelArray {
            // A to-many relationship holds no order, so it is compared as a set of identities.
            if Set(wasMembers.memberIDs) == Set(nowMembers.memberIDs) { return .same }
            guard let resolved = (Value.self as? any RevertModelArray.Type)?
                .resolving(wasMembers.memberIDs, in: context) as? Value else {
                return .unresolvable("a to-many member could not be resolved in the reverted context")
            }
            row[keyPath: self] = resolved
            return .written
        }
        if let optionalType = Value.self as? any RevertOptionalModel.Type {
            let wasID = (was as? any RevertOptionalModel)?.memberID
            let nowID = (now as? any RevertOptionalModel)?.memberID
            if wasID == nowID { return .same }
            guard let resolved = optionalType.resolving(wasID, in: context) as? Value else {
                return .unresolvable("a to-one member could not be resolved in the reverted context")
            }
            row[keyPath: self] = resolved
            return .written
        }
        if let comparable = was as? any Equatable {
            if comparable.revertEquals(now) { return .same }
            row[keyPath: self] = was
            return .written
        }
        row[keyPath: self] = was
        return .writtenUncompared
    }
}
