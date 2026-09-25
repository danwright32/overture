import Foundation
import SwiftData

// #4252: the stored properties of every model, so a `ScopeMemo` can re-arm observation on them and compare
// a row's values across contexts.
//
// WHY THIS EXISTS. SwiftData's `@Query` refetches after every save, and the refetch calls `willSet` on every
// field of every row it returns whether or not anything changed: measured under #4253, an untouched show
// fired all 136 of its fields. A memo marked stale by observation cannot tell that refetch from an edit, so
// one saved change derived the queue twice (#4106). Serving the refetch the answer it already has needs two
// things this file supplies:
//
//   1. RE-ARMING. The refetch spends the tracking the build armed, and the only supported way to register
//      observation on a field is the model's own `access`. So a served answer re-registers on every stored
//      property of every row it was handed (`armAll`), a superset of what the build read, so no later edit
//      can be missed. Measured on the live store (1,340 shows): 134 ms, against a 364 ms queue pass.
//   2. VALUES, for the one change observation and the save count cannot settle: a write saved through
//      ANOTHER context whose merge reaches this one after a build. `StoreSaveCount` reads the saved rows'
//      values on the saving context, and the memo compares the main context's copy of each with them.
//
// WHY NOT COMPARE EVERY VALUE ON EVERY REFETCH, which was the first version of this (Dan's call, 2026-09-25
// in chat: compare values, with supported API only). Measured on the live store it costs more than the
// derivation it saves: 185 ms to snapshot 241,488 values beside a build and 264 ms to compare them on the
// refetch, against a 364 ms pass (`ScopeValueComparisonCostTests`). So values are compared only where they
// are the one thing that can answer, and the main context's own refetch is recognised by what supported API
// can state for free: no save has happened since the build and the context holds nothing unsaved.
//
// The per model lists are in `ScopeFields.swift` and held to the schema by `ScopeFieldsMatchTheSchemaTests`,
// so a property added to a model and not there fails the suite rather than going unwatched (L41, L96).

/// One stored property of a model: how to register observation on it, and how to read and compare it.
///
/// `@unchecked Sendable` because every field is a `let` set once, in the static list that declares it, and
/// holds only a key path and closures that act on the row they are handed. Nothing in it is ever mutated,
/// so sharing the lists across isolation domains shares no mutable state.
struct ScopeField<Root: ScopeCompared>: @unchecked Sendable {
    /// The property, kept so the guard can name it against the schema.
    let keyPath: AnyKeyPath
    /// Read through the backing data, which registers NO observation.
    let value: (Root) -> Any
    /// Whether two readings are the same value. Typed inside, so no reading is ever hashed (#3656).
    let same: (Any, Any) -> Bool
    /// The rows this property reaches, which are armed too. Empty for an attribute.
    let reaches: (Root) -> [any ScopeCompared]
    /// Registers observation on this property WITHOUT reading it, through the model's own `access`.
    let arm: (Root) -> Void

    init<V: Equatable & Decodable>(_ keyPath: KeyPath<Root, V>) {
        self.keyPath = keyPath
        value = { $0.getValue(forKey: keyPath) }
        // A forced cast, not a defaulted one: both sides were produced by `value` above, so a mismatch is
        // a broken assumption and must crash rather than read as "changed" or "same" (L67).
        same = { ($0 as! V) == ($1 as! V) }
        reaches = { _ in [] }
        arm = { $0.scopeAccess(keyPath) }
    }

    /// A to-many relationship. Its value is WHICH rows it holds, in order, by persistent identity, because
    /// the comparison it serves is between two contexts and an object identity means nothing across them.
    init<M: ScopeCompared>(toMany keyPath: KeyPath<Root, [M]>) {
        self.keyPath = keyPath
        value = { $0.getValue(forKey: keyPath).map(\.persistentModelID) }
        same = { ($0 as! [PersistentIdentifier]) == ($1 as! [PersistentIdentifier]) }
        reaches = { $0.getValue(forKey: keyPath) }
        arm = { $0.scopeAccess(keyPath) }
    }

    /// A to-one relationship, compared by which row it points at. Not walked into: the only one in the
    /// schema is a recipient's way back to its show, which is always reached from that show.
    init<M: PersistentModel>(toOne keyPath: KeyPath<Root, M?>) {
        self.keyPath = keyPath
        value = { $0.getValue(forKey: keyPath)?.persistentModelID as Any }
        same = { ($0 as! PersistentIdentifier?) == ($1 as! PersistentIdentifier?) }
        reaches = { _ in [] }
        arm = { $0.scopeAccess(keyPath) }
    }
}

/// A model whose stored properties a `ScopeMemo` can watch and compare. Every model in `AppSchema`
/// conforms, and `ScopeFieldsMatchTheSchemaTests` holds each list to the schema.
protocol ScopeCompared: PersistentModel {
    static var scopeFields: [ScopeField<Self>] { get }
    /// The same fields, untyped, so the guard can name them from an existential.
    static var scopeKeyPaths: [AnyKeyPath] { get }
    /// The model's own observation registration for one property, which `@Model` generates as `access`.
    func scopeAccess<V>(_ keyPath: KeyPath<Self, V>)
}

extension ScopeCompared {
    static var scopeKeyPaths: [AnyKeyPath] { scopeFields.map(\.keyPath) }

    func armAll(seen: inout Set<ObjectIdentifier>) {
        guard seen.insert(ObjectIdentifier(self)).inserted else { return }
        for field in Self.scopeFields {
            field.arm(self)
            for next in field.reaches(self) { next.armAll(seen: &seen) }
        }
    }

    /// This row's own values, in field order, read without registering observation. Its relationships
    /// are read as which rows they hold, not walked into: a related row that changed is a row of its own
    /// in whatever save changed it.
    var scopeValues: [Any] { Self.scopeFields.map { $0.value(self) } }

    /// Whether this row's values are `stored`, which `scopeValues` produced from a row of the same model.
    func scopeValuesMatch(_ stored: [Any]) -> Bool {
        let fields = Self.scopeFields
        guard stored.count == fields.count else { return false }
        for (field, value) in zip(fields, stored) where !field.same(value, field.value(self)) { return false }
        return true
    }

    /// The copy of this row that `context` holds, if it holds one already. Never faults one in: a context
    /// that has not loaded the row has nothing stale to compare, and loading it here would be a fetch.
    static func registered(_ id: PersistentIdentifier, in context: ModelContext) -> Self? {
        context.registeredModel(for: id)
    }
}

/// The rows a `ScopeFingerprint` was given, kept so observation can be re-armed on them.
///
/// Kept as one closure per collection over the TYPED array rather than as an array of existentials, so a
/// body evaluation that never needs to re-arm (every plain hit) pays nothing to convert 1,340 rows.
struct ScopeValueSources {
    private var armers: [(inout Set<ObjectIdentifier>) -> Void] = []

    mutating func add<Element: ScopeCompared>(_ rows: [Element]) {
        armers.append { seen in for row in rows { row.armAll(seen: &seen) } }
    }

    var isEmpty: Bool { armers.isEmpty }

    /// Registers observation on every stored property of every row, and of every row those reach, reading
    /// none of them. Called inside tracking, it arms that tracking; inside a view's body, it keeps the body
    /// subscribed too, because observation merges an inner scope's registrations into the enclosing one.
    func armAll() {
        var seen = Set<ObjectIdentifier>()
        for arm in armers { arm(&seen) }
    }
}
