import Foundation
import SwiftData

// #4334 (A5): the failure path revert, candidate (ii) of decision 2. Built by #4327 step 0.8 as a probe in the
// test target, where its correctness cases and its cost were measured rather than argued (L246, L574:
// `FailurePathRevertProbeTests`, a median 37.2 ms on the hardest real source at 4x), and shipped here once
// every case held. Its one caller is `ScoutLandingStore.revertFailedSave`, which a landing calls when a
// source's save, or its closing save, fails. It never calls `rollback()`, which is banned on every context in
// the app (`LandingSaveFailureTests.nothingInTheAppRollsAContextBack`).
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
// reported in `notRestorable`, never silently skipped, and the landing then stops as "not reverted", by name.
// Nothing on the landing path deletes a committed row, and
// `LandingSaveFailureTests.theLandingPathDeletesNoSavedRow` keeps that true.
//
// WHAT IT LEAVES. A field written back to its committed value still reads as changed, and nothing short of a
// save clears that (measured, `LandingSaveFailureTests.aFieldWrittenBackStillReadsAsChanged`). So a reverted
// context differs from the store in nothing, but `hasChanges` stays true until the next save, which writes
// the same values again. The next landing's entry flush is that save.
//
// It restores COMMITTED values, which equal the values just before the failed turn only if nothing the revert
// touches was pending before that turn began. That is what the landing's entry flush guarantees
// (`ScoutService.flushBeforeLanding`), and the correctness tests show both halves: with the flush a pending
// edit survives, without it the edit is reverted.
@MainActor
enum LandingRevert {
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

        /// This set and the other, each row once.
        func adding(_ other: WriteSet) -> WriteSet {
            func merged(_ a: [any PersistentModel], _ b: [any PersistentModel]) -> [any PersistentModel] {
                var seen = Set(a.map(\.persistentModelID))
                return a + b.filter { seen.insert($0.persistentModelID).inserted }
            }
            return WriteSet(changed: merged(changed, other.changed), inserted: merged(inserted, other.inserted),
                            deleted: merged(deleted, other.deleted))
        }

        /// This set without the rows named, which stay pending for a later save.
        func excluding(_ ids: Set<PersistentIdentifier>) -> WriteSet {
            guard !ids.isEmpty else { return self }
            return WriteSet(changed: changed.filter { !ids.contains($0.persistentModelID) },
                            inserted: inserted.filter { !ids.contains($0.persistentModelID) },
                            deleted: deleted.filter { !ids.contains($0.persistentModelID) })
        }
    }

    /// The pending set as the FIRST save after this is made begins, which is the write set a failed save
    /// carried: what the landing's `willSave` observer records. Held for as long as the capture is.
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

    // copy-inventory:ignore-start  the revert's diagnostic reasons and counts, carried in LandingStop.notReverted and in test output, never shown to Dan (#4334)
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
        let committed = CommittedStore(context.container)
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
        // A delete is only pending until the context processes it, and until then the row is still listed as
        // inserted and still returned by a fetch. Processed here so the context reads as the store does.
        context.processPendingChanges()
        return report
    }

    // #4338 (A10): what `revert` WOULD change, without changing it, so the discard of unsaved edits can name
    // the rows and the fields before Dan confirms it (L180). The same three groups the revert works through and
    // the same comparison per field (`RevertibleField.compare`), so the confirmation and the revert cannot
    // disagree about which fields go back.
    struct Difference {
        enum Kind: Equatable {
            // A saved row with these fields edited, named by property. Empty when its saved copy could not be
            // read, so which fields differ is unknown: the row is still named, never left out.
            case changed(fields: [String])
            // A row never saved, which the revert takes back out.
            case inserted
            // A saved row the edits removed, which the revert cannot bring back.
            case deleted
        }
        var model: any PersistentModel
        var kind: Kind
    }

    static func differences(_ set: WriteSet, in context: ModelContext) -> [Difference] {
        let committed = CommittedStore(context.container)
        let insertedIDs = Set(set.inserted.map(\.persistentModelID))
        var out: [Difference] = []
        for model in set.changed where !insertedIDs.contains(model.persistentModelID) {
            guard let row = model as? any ScopeObserved else { continue }
            guard let fields = changedFields(row, from: committed) else {
                out.append(Difference(model: model, kind: .changed(fields: [])))
                continue
            }
            if !fields.isEmpty { out.append(Difference(model: model, kind: .changed(fields: fields))) }
        }
        for model in set.inserted { out.append(Difference(model: model, kind: .inserted)) }
        for model in set.deleted where !insertedIDs.contains(model.persistentModelID) {
            out.append(Difference(model: model, kind: .deleted))
        }
        return out
    }

    // The properties of one changed row whose value differs from its committed one, by name, or nil when its
    // committed copy cannot be read.
    private static func changedFields<M: ScopeObserved>(_ row: M, from committed: CommittedStore) -> [String]? {
        guard let base = committed.row(row.persistentModelID, as: M.self) else { return nil }
        return M.scopeFields.compactMap { field -> String? in
            guard let path = field.keyPath as? any RevertibleField else { return nil }
            switch path.compare(committed: base, row: row) {
            case .same: return nil
            case .differs, .uncompared, .unresolvable: return propertyName(field.keyPath)
            }
        }
    }

    // A key path's property name, `\Prospect.sourceListingURL` read as "source listing URL": split where a word
    // starts, an acronym kept whole, with the `Raw` a stored enum's backing field ends in dropped. Never a type
    // name, never a path.
    static func propertyName(_ keyPath: AnyKeyPath) -> String {
        let described = String(describing: keyPath)
        guard let dot = described.lastIndex(of: ".") else { return "a field" }
        var name = Array(described[described.index(after: dot)...])
        if name.count > 3, String(name.suffix(3)) == "Raw" { name.removeLast(3) }
        var words: [String] = []
        var current = ""
        for (i, ch) in name.enumerated() {
            let afterLower = i > 0 && name[i - 1].isLowercase
            let endsAcronym = i > 0 && name[i - 1].isUppercase && i + 1 < name.count && name[i + 1].isLowercase
            if ch.isUppercase, !current.isEmpty, afterLower || endsAcronym {
                words.append(current)
                current = ""
            }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        let spoken = words.map { $0.count > 1 && $0.allSatisfy(\.isUppercase) ? $0 : $0.lowercased() }
        return spoken.isEmpty ? "a field" : spoken.joined(separator: " ")
    }

    // The store as last saved, read through a context of its own that only ever READS
    // (`OnlyTheMainContextWritesGuardTests`): one per revert, made the first time a row needs it.
    private final class CommittedStore {
        private let container: ModelContainer
        init(_ container: ModelContainer) { self.container = container }
        private lazy var reader = ModelContext(container)

        func row<M: PersistentModel>(_ id: PersistentIdentifier, as _: M.Type) -> M? {
            var descriptor = FetchDescriptor<M>(predicate: #Predicate { $0.persistentModelID == id })
            descriptor.fetchLimit = 1
            return (try? reader.fetch(descriptor))?.first
        }
    }

    private static func revertRow<M: ScopeObserved>(_ row: M, from committed: CommittedStore, into context: ModelContext,
                                                   report: inout Report) {
        guard let base = committed.row(row.persistentModelID, as: M.self) else {
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

/// #4338: what one field's committed value says beside the row's current one, without writing anything. The
/// revert below writes on `differs` and `uncompared`; the discard confirmation (`UnsavedEditsDiscard`) names the
/// fields that would be written, from the same comparison, so the two can never disagree about a field (L263).
enum FieldComparison: Equatable { case same, differs, uncompared, unresolvable(String) }

/// A key path whose committed value can be copied onto the row being reverted.
protocol RevertibleField {
    @MainActor func compare(committed: Any, row: Any) -> FieldComparison
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
    @MainActor func compare(committed: Any, row: Any) -> FieldComparison {
        guard let base = committed as? Root, let row = row as? Root else { return .unresolvable("wrong root") }
        let was = base[keyPath: self]
        let now = row[keyPath: self]
        if let wasMembers = was as? any RevertModelArray, let nowMembers = now as? any RevertModelArray {
            // A to-many relationship holds no order, so it is compared as a set of identities.
            return Set(wasMembers.memberIDs) == Set(nowMembers.memberIDs) ? .same : .differs
        }
        if Value.self is any RevertOptionalModel.Type {
            let wasID = (was as? any RevertOptionalModel)?.memberID
            let nowID = (now as? any RevertOptionalModel)?.memberID
            return wasID == nowID ? .same : .differs
        }
        if let comparable = was as? any Equatable { return comparable.revertEquals(now) ? .same : .differs }
        return .uncompared
    }

    @MainActor func revert(from committed: Any, to row: Any, resolvingIn context: ModelContext) -> RevertStep {
        let comparison = compare(committed: committed, row: row)
        switch comparison {
        case .same: return .same
        case .unresolvable(let why): return .unresolvable(why)
        case .differs, .uncompared: break
        }
        guard let base = committed as? Root, let row = row as? Root else { return .unresolvable("wrong root") }
        let was = base[keyPath: self]
        if let wasMembers = was as? any RevertModelArray {
            guard let resolved = (Value.self as? any RevertModelArray.Type)?
                .resolving(wasMembers.memberIDs, in: context) as? Value else {
                return .unresolvable("a to-many member could not be resolved in the reverted context")
            }
            row[keyPath: self] = resolved
            return .written
        }
        if let optionalType = Value.self as? any RevertOptionalModel.Type {
            let wasID = (was as? any RevertOptionalModel)?.memberID
            guard let resolved = optionalType.resolving(wasID, in: context) as? Value else {
                return .unresolvable("a to-one member could not be resolved in the reverted context")
            }
            row[keyPath: self] = resolved
            return .written
        }
        row[keyPath: self] = was
        return comparison == .uncompared ? .writtenUncompared : .written
    }
}
// copy-inventory:ignore-end
