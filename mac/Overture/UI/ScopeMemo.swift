import Foundation
import Observation

// #3879: a whole-store derivation that runs once per CHANGE rather than once per body evaluation.
//
// WHAT IT IS FOR. `ArchiveView.body` calls `makeScope()` unconditionally, and that derives the whole
// table: 385.3 ms over 1,224 rows, measured 2026-09-13. #3876 and #3878 removed ONE cause of a body
// evaluation that changed nothing (a view-level `@Environment(\.dismiss)` read, revised on every focus
// change). The derivation is still unconditional, so every OTHER cause still pays a whole-store pass,
// and those causes cannot be enumerated from the data (L471). This makes the pass conditional instead
// of chasing the triggers one at a time.
//
// THE TRAP THIS IS DESIGNED AROUND, stated first because it decides the whole shape. A cheap key that
// MISSES a change shows stale rows, which is worse than a slow screen (L40). So the key is in four
// parts, and each part exists because the other three cannot see what it sees:
//
//   1. THE IDENTITY FINGERPRINT of every input collection. Hashes each element's `ObjectIdentifier`,
//      in order, which sees an insert, a delete, a replacement and a reorder exactly. It is O(n) over
//      pointers rather than over fields: measured below in `ScopeMemoTests`, and a pointer hash of
//      1,233 rows is microseconds against a derivation of hundreds of milliseconds. Comparing the model
//      arrays BY VALUE would be whole-store work, which trades one O(n) pass for a cheaper one rather
//      than removing it, and a COUNT would be blind to a row swapped for another (L40).
//   2. OBSERVATION TRACKING, which is what a fingerprint cannot do. A `@Model` object is `@Observable`,
//      so a field edited IN PLACE leaves every pointer where it was and changes what the derivation
//      would produce. The build runs inside `withObservationTracking`, so the memo is marked stale by
//      the same mechanism that invalidates the body: precisely when a value the derivation READ
//      changes, and never on a value it did not read.
//   3. THE CARD KEYS the frame asked for, because a scroll changes which cards the pass must build
//      while changing no row. They arrive drained from the registry (`takeKeys()`), which is why the
//      caller must drain on EVERY evaluation and hand the result in: skipping the drain would let the
//      registry accumulate every frame's keys and quietly grow the next real pass.
//   4. A TTL. `QueueModel.scope` takes `now` and derives Overture's day from it, and this memo cannot
//      prove that the day is the only thing in that derivation the clock reaches without reading all
//      of it. So rather than assert something unmeasured, the memo simply refuses to serve an answer
//      older than `staleAfter`. That bounds any clock staleness to a value stated here, at the cost of
//      one rebuild per window on a screen nobody is touching, and the windows this exists to collapse
//      are the bursts of passes inside a single second.
//
// WHAT IT DOES NOT DO. It does not make the derivation cheaper. A miss costs exactly what the
// derivation always cost, and the first evaluation after any change is a miss. It changes how OFTEN
// the cost is paid, which is the quantity #3879 is about and the one L383 says a call site cannot show.
@MainActor
final class ScopeMemo<Value> {

    /// How long an answer may be served before the clock alone makes it stale. See part 4 above.
    static var staleAfterSeconds: Double { 2 }

    private struct Key: Equatable {
        let fingerprint: Int
        let cardKeys: Set<String>
    }

    private var key: Key?
    private var value: Value?
    private var builtAt: Date?
    // Written by `withObservationTracking`'s onChange, which fires on whatever thread performed the
    // mutation. `@MainActor` on the class is not enough on its own, so this one field is isolated by a
    // lock rather than by the actor.
    private let staleFlag = StaleFlag()

    /// How many times the builder actually ran. The quantity the guard asserts, because "it was fast"
    /// is a statement about the machine and "it did not build" is a statement about this code (L63).
    private(set) var builds = 0

    init() {}

    /// The derivation's answer, rebuilt only when one of the four parts of the key has moved.
    ///
    /// `fingerprintOf` is handed in rather than computed here so the caller names its own inputs, which
    /// is what makes an input added to the caller and not to the fingerprint a visible omission rather
    /// than a silent one. `ScopeMemoInputsAreCompleteGuardTests` is the half that makes it visible.
    func value(fingerprint: Int,
               cardKeys: Set<String>,
               now: Date,
               build: () -> Value) -> Value {
        let wanted = Key(fingerprint: fingerprint, cardKeys: cardKeys)
        if !staleFlag.isSet,
           let key, key == wanted,
           let value,
           let builtAt,
           now.timeIntervalSince(builtAt) < Self.staleAfterSeconds {
            return value
        }

        var built: Value?
        staleFlag.clear()
        withObservationTracking {
            built = build()
        } onChange: { [staleFlag] in
            staleFlag.set()
        }
        // `withObservationTracking` runs its `apply` closure synchronously and exactly once, so this is
        // set by the time control reaches here. Force unwrapped rather than defaulted, because a default
        // would turn a broken assumption into a plausible answer instead of a crash (L67).
        let result = built!
        builds += 1
        key = wanted
        value = result
        builtAt = now
        return result
    }

}

/// The identity half of a `ScopeMemo` key: each input collection hashed by its elements' identities, in
/// order. Sees an insert, a delete, a replacement and a reorder exactly; sees no field edit at all,
/// which is observation tracking's job.
///
/// A BUILDER with one `add` per input rather than one call taking everything, and that shape is the
/// point. Each of a view's inputs is named at the call site, so an input added to the view and not to
/// the key is a line that is missing rather than an argument that is subtly wrong, and
/// `ScopeMemoInputsAreCompleteGuardTests` can see it (L96).
struct ScopeFingerprint {
    private var hasher = Hasher()

    init() {}

    mutating func add<Element: AnyObject>(_ items: [Element]) {
        // The count is combined as well as the members, so two adjacent inputs cannot trade an element
        // and leave the running hash identical.
        hasher.combine(items.count)
        for item in items { hasher.combine(ObjectIdentifier(item)) }
    }

    /// A value that is not a collection of model objects, for an input a derivation reads that the store
    /// cannot see: a marker file's answer, a connection flag, a stage. Named `value:` rather than
    /// overloading `add` so an array of `Hashable` elements cannot silently match the wrong one.
    mutating func add(value: some Hashable) {
        hasher.combine(value)
    }

    func finalized() -> Int { hasher.finalize() }
}

/// A Bool that may be set from any thread, because `withObservationTracking`'s onChange runs wherever
/// the mutation happened.
final class StaleFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = true

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        flag = true
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        flag = false
    }
}
