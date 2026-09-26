import Foundation
import SwiftData

// #4252: the stored properties of every model, so a `ScopeMemo` can re-arm observation on them.
//
// WHY THIS EXISTS. SwiftData's `@Query` refetches after every save, and the refetch calls `willSet` on every
// field of every row it returns whether or not anything changed: measured under #4253, an untouched show
// fired all 136 of its fields. A memo marked stale by observation cannot tell that refetch from an edit, so
// one saved change derived the queue twice (#4106). `ScopeMemo` now recognises the refetch (see its
// `Refetch`), and serving it the answer it already has needs one thing from here: RE-ARMING. The refetch
// spends the tracking the build armed, and the only supported way to register observation on a field is
// the model's own `access`. So a served answer re-registers on every stored property of every row it was
// handed (`armAll`), a superset of what the build read, so no later edit can be missed. Measured on the
// live store (1,340 shows, 529 recipients): 123 ms, against a 366 ms queue pass.
//
// WHY NOT COMPARE VALUES, which was the first version of this (Dan's call, 2026-09-25 in chat: compare
// values, with supported API only). Measured on the live store it cost more than the derivation it saved:
// 185 ms to snapshot 241,488 stored values beside a build and 264 ms to compare them on the refetch,
// against a 364 ms pass. What `ScopeMemo` reads instead is what supported API states for nothing: no save
// has happened since the build, the main context holds nothing unsaved, and no other context has saved.
//
// The per model lists are in `ScopeFields.swift` and held to the schema by `ScopeFieldsMatchTheSchemaTests`,
// so a property added to a model and not there fails the suite rather than going unwatched (L41, L96).

/// One stored property of a model, and how to register observation on it.
///
/// `@unchecked Sendable` because every field is a `let` set once, in the static list that declares it, and
/// holds only a key path and closures that act on the row they are handed. Nothing in it is ever mutated,
/// so sharing the lists across isolation domains shares no mutable state.
struct ScopeField<Root: ScopeObserved>: @unchecked Sendable {
    /// The property, kept so the guard can name it against the schema.
    let keyPath: AnyKeyPath
    /// The rows this property reaches, which are armed too. Empty for an attribute.
    let reaches: (Root) -> [any ScopeObserved]
    /// Registers observation on this property WITHOUT reading it, through the model's own `access`.
    let arm: (Root) -> Void

    init<V>(_ keyPath: KeyPath<Root, V>) {
        self.keyPath = keyPath
        reaches = { _ in [] }
        arm = { $0.scopeAccess(keyPath) }
    }

    /// A to-many relationship, armed itself and walked into, so the rows it holds are armed too.
    init<M: ScopeObserved>(toMany keyPath: KeyPath<Root, [M]>) {
        self.keyPath = keyPath
        reaches = { $0.getValue(forKey: keyPath) }
        arm = { $0.scopeAccess(keyPath) }
    }

    /// A to-one relationship, armed but not walked into: the only one in the schema is a recipient's way
    /// back to its show, which is always reached from that show.
    init<M: PersistentModel>(toOne keyPath: KeyPath<Root, M?>) {
        self.keyPath = keyPath
        reaches = { _ in [] }
        arm = { $0.scopeAccess(keyPath) }
    }
}

/// A model whose stored properties a `ScopeMemo` can watch. Every model in `AppSchema`
/// conforms, and `ScopeFieldsMatchTheSchemaTests` holds each list to the schema.
protocol ScopeObserved: PersistentModel {
    static var scopeFields: [ScopeField<Self>] { get }
    /// The same fields, untyped, so the guard can name them from an existential.
    static var scopeKeyPaths: [AnyKeyPath] { get }
    /// The model's own observation registration for one property, which `@Model` generates as `access`.
    func scopeAccess<V>(_ keyPath: KeyPath<Self, V>)
}

extension ScopeObserved {
    static var scopeKeyPaths: [AnyKeyPath] { scopeFields.map(\.keyPath) }

    func armAll(seen: inout Set<ObjectIdentifier>) {
        guard seen.insert(ObjectIdentifier(self)).inserted else { return }
        for field in Self.scopeFields {
            field.arm(self)
            for next in field.reaches(self) { next.armAll(seen: &seen) }
        }
    }
}

/// The rows a `ScopeFingerprint` was given, kept so observation can be re-armed on them.
///
/// Kept as one closure per collection over the TYPED array rather than as an array of existentials, so a
/// body evaluation that never needs to re-arm (every plain hit) pays nothing to convert 1,340 rows.
struct ScopeRows {
    private var armers: [(inout Set<ObjectIdentifier>) -> Void] = []

    mutating func add<Element: ScopeObserved>(_ rows: [Element]) {
        armers.append { seen in for row in rows { row.armAll(seen: &seen) } }
    }

    var isEmpty: Bool { armers.isEmpty }

    /// Registers observation on every stored property of every row, and of every row those reach, reading
    /// only the relationships it walks. Called inside tracking, it arms that tracking; inside a view's body, it keeps the body
    /// subscribed too, because observation merges an inner scope's registrations into the enclosing one.
    func armAll() {
        var seen = Set<ObjectIdentifier>()
        for arm in armers { arm(&seen) }
    }
}
