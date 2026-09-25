import Foundation
import Observation
import SwiftData

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
    ///
    /// The DEFAULT, for a derivation that reads the clock. A derivation that does not read it at all
    /// passes `staleAfter: .never`, and #3742 is why that exists: the producer tables are a function of
    /// the corpus's presenter and venue pairs and the overrides, with no clock anywhere in them, so a
    /// two second window there is not a safeguard, it is one rebuild of a 68 ms table every two seconds
    /// of active use, bought for nothing. A TTL that cannot protect anything is overhead wearing the
    /// clothes of a guard.
    static var staleAfterSeconds: Double { 2 }

    /// How long this memo's answer may be served before the clock alone makes it stale.
    ///
    /// Spelled as a TYPE rather than as an optional Double so the two cases are named at the call site:
    /// `.seconds(2)` says a clock reaches this derivation and here is the bound, `.never` says it does
    /// not. An optional would make the second case read as "nobody set one" (L544).
    enum Staleness {
        case seconds(Double)
        case never
        // #4110: expired once a NAMED INSTANT has arrived, rather than after a fixed window.
        //
        // For a derivation that can say when its own answer could next change, a window is the wrong
        // shape twice over: too long and the answer goes stale, too short and the derivation is re-run
        // for nothing. `RootView.followUpsDue` measured the second half of that. Its window was two
        // seconds and its build is a whole-store sweep over every prospect and every recipient's
        // conversation state, so any use of the app longer than two seconds paid the sweep again, and a
        // 6.81s freeze on 2026-09-21 contained two of them. `DueWork.nextChange` already answers "the
        // earliest future moment at which a rule already in play comes due", so the answer carries its
        // own expiry and this is how the memo is told it.
        //
        // A `Date` rather than an optional: a derivation with NO next moment passes `.never`, which
        // already says exactly that, and an optional here would make "nothing can change it" and
        // "nobody set one" the same value (L544).
        case at(Date)

        func hasExpired(builtAt: Date, now: Date) -> Bool {
            switch self {
            case .seconds(let window): return now.timeIntervalSince(builtAt) >= window
            case .never: return false
            case .at(let moment): return now >= moment
            }
        }
    }

    private struct Key: Equatable {
        let fingerprint: Int
        let cardKeys: Set<String>
    }

    private var key: Key?
    private var value: Value?
    private var builtAt: Date?
    // #4106: the store's save count when the answer was built. See `value(...)`'s `savesIn`.
    private var savesAtBuild: Int?
    private let saves: StoreSaveCount

    /// `saves` is injected so a test can drive the save count with notifications of its own rather than
    /// sharing the one every concurrently running suite writes to.
    init(saves: StoreSaveCount = .shared) {
        self.saves = saves
    }
    // Written by `withObservationTracking`'s onChange, which fires on whatever thread performed the
    // mutation. `@MainActor` on the class is not enough on its own, so this one field is isolated by a
    // lock rather than by the actor.
    private let staleFlag = StaleFlag()

    /// The answer this memo is currently holding, without building one.
    ///
    /// #4110: read by a caller whose staleness window is a property of the VALUE rather than a constant,
    /// which is the only way `.at` above can be given the instant the LAST build worked out. The
    /// alternative is holding that instant in a second piece of state beside the memo, and a value and
    /// the fact describing it are one fact, not two (L544).
    ///
    /// It deliberately does NOT consult the key, the stale flag or the clock: it answers "what is in
    /// here", never "is that still good". A caller that used it as an answer would be reading around the
    /// memo, so the one caller uses it only to build the key it then passes back in.
    var held: Value? { value }

    /// How many times the builder actually ran. The quantity the guard asserts, because "it was fast"
    /// is a statement about the machine and "it did not build" is a statement about this code (L63).
    private(set) var builds = 0

    /// The derivation's answer, rebuilt only when one of the four parts of the key has moved.
    ///
    /// `fingerprintOf` is handed in rather than computed here so the caller names its own inputs, which
    /// is what makes an input added to the caller and not to the fingerprint a visible omission rather
    /// than a silent one. `ScopeMemoInputsAreCompleteGuardTests` is the half that makes it visible.
    ///
    /// #4106: `savesIn` is the FIFTH part of the key, and it is REQUIRED so no caller can leave it out.
    /// A write saved through a context other than the one the derivation read from reaches this view as a
    /// merge and a refetch, which can leave every identity where it was and fire no observed field, so
    /// the four parts above all hold still and the memo served the answer from before the save: measured
    /// on the queue, where `FeltWaitCostTests` writes through a second context and the memoised queue
    /// never rebuilt (L40). So any save into the store a derivation reads makes its answer stale. A
    /// derivation that reads no store, or whose fingerprint already hashes the CONTENT it reads, passes
    /// nil and says why at the call site.
    func value(fingerprint: Int,
               cardKeys: Set<String>,
               now: Date,
               staleAfter: Staleness = .seconds(ScopeMemo.staleAfterSeconds),
               savesIn store: ModelContainer?,
               build: () -> Value) -> Value {
        let wanted = Key(fingerprint: fingerprint, cardKeys: cardKeys)
        let savesNow = store.map { saves.value(for: $0) }
        if !staleFlag.isSet,
           savesAtBuild == savesNow,
           let key, key == wanted,
           let value,
           let builtAt,
           !staleAfter.hasExpired(builtAt: builtAt, now: now) {
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
        savesAtBuild = savesNow
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
