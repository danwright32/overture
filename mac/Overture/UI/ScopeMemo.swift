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
//      than removing it, and a COUNT would be blind to a row swapped for another (L40). An address names an
//      object only while it lives, so the memo HOLDS the rows its key was taken over until the next build
//      (#4612): no other row can be made at one of their addresses while that key is compared.
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
    // #4612: the rows `key`'s fingerprint was taken over, HELD for as long as that key is. The fingerprint hashes
    // addresses, and an address names an object only while it lives (L1019), so holding them is what makes two
    // equal hashes mean the same rows: no other object can be made at one of these addresses while they are here.
    private var keyRows = ScopeRows()
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

    /// #4252: how many times observation said the answer was stale, nothing had been saved since the build
    /// and nothing was unsaved, so it was served and observation re-armed rather than the derivation run.
    /// Read by the tests beside `builds`, because a zero here with a build count that did not move would
    /// mean the refetch never reached this memo, which is not the same as it being served (L98).
    private(set) var servedUnchanged = 0

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
    /// never rebuilt (L40). (App code never writes through a second context, which reverts concurrent
    /// edits, #4252; the save count still covers every context, since a test does.) So any save into the store a derivation reads makes its answer stale. A
    /// derivation that reads no store, or whose fingerprint already hashes the CONTENT it reads, passes
    /// nil and says why at the call site.
    ///
    /// #4612: keyed by a `ScopeFingerprint` rather than the bare hash it finalizes to, so the memo can hold the rows
    /// the hash was taken over (`keyRows`). The hash is of ADDRESSES, and an address names an object only while it
    /// lives (L1019): a row freed after the build and another made at its address hashed identically, and the memo
    /// served the first row's answer for the second (`ScopeMemoTests.aRowMadeAtAFreedRowsAddressRebuilds`).
    func value(fingerprint: ScopeFingerprint,
               cardKeys: Set<String>,
               now: Date,
               staleAfter: Staleness = .seconds(ScopeMemo.staleAfterSeconds),
               savesIn store: ModelContainer?,
               build: () -> Value) -> Value {
        resolve(fingerprint: fingerprint, cardKeys: cardKeys, now: now, staleAfter: staleAfter,
                savesIn: store, build: build)
    }

    /// #4252: what an observed change means when nothing has been saved since the build.
    ///
    /// Required of every caller keyed by a `ScopeFingerprint`, with its reason at the call site, because the
    /// right answer depends on what the derivation costs, which only the caller knows. Serving means
    /// re-registering observation on every stored property of every row, which is 134 ms over the live
    /// store (1,340 shows, measured 2026-09-25): well under a 364 ms queue pass, well OVER a 27 ms Due
    /// count, which is cheaper to derive again than to re-arm.
    enum Refetch {
        /// Derive again, as every observed change always did.
        case rebuild
        /// Serve the answer and re-arm, when no save has happened since the build and nothing is unsaved.
        case serveWhenNothingChanged
    }

    /// #4252: the same, keyed by a `ScopeFingerprint`, which also carries the rows it was given, so a
    /// refetch that changed nothing can be served rather than derived again.
    ///
    /// WHAT CHANGES. SwiftData's `@Query` refetches after every save and calls `willSet` on every field of
    /// every row it returns, changed or not, so observation marks the answer stale a second time for one
    /// saved change (#4106). With `.serveWhenNothingChanged`, an answer marked stale by observation alone is
    /// served when the identities, card keys and clock are where they were, NO save into the store has
    /// happened since the build (a change made and saved after the build moves the save count, which still
    /// rebuilds), the main context holds nothing unsaved (a change made and not saved), and the store has
    /// never taken a save through another context (whose merge can land after a build with no save behind
    /// it; `StoreSaveCount.hasForeignSaves`). Those are every way a row's value can change, so what is left
    /// is the refetch.
    ///
    /// WHAT KEEPS IT HONEST. The refetch spent the tracking the build armed, so serving re-arms it on every
    /// stored property of every row (`ScopeRows.armAll`): a superset of what the build read, so no
    /// later edit is missed, and inside a view's body it keeps the body subscribed too.
    ///
    /// WHAT IT ASSUMES, stated because nothing can check it: the build reads model rows and the values
    /// already in the key, and no other observable object. A derivation reading some other `@Observable`
    /// would have that change served as a refetch. Every derivation keyed this way is a static function of
    /// the inputs its caller names (`ScopeMemoInputsAreCompleteGuardTests` holds the model half).
    func value(fingerprint: ScopeFingerprint,
               cardKeys: Set<String>,
               now: Date,
               staleAfter: Staleness = .seconds(ScopeMemo.staleAfterSeconds),
               savesIn store: ModelContainer,
               onRefetch: Refetch,
               build: () -> Value) -> Value {
        let wanted = Key(fingerprint: fingerprint.finalized(), cardKeys: cardKeys)
        let savesNow = saves.value(for: store)
        if let current = held(wanted, now: now, staleAfter: staleAfter), savesAtBuild == savesNow {
            if !staleFlag.isSet { return current }
            if servesRefetch(onRefetch, in: store) {
                rearm(fingerprint) {}
                return current
            }
        }
        return rebuild(wanted, rows: fingerprint.sources, now: now, savesNow: savesNow, build: build)
    }

    /// #4252: whether an answer observation has marked stale, with no save since its build, is a refetch
    /// that changed nothing, which may be served. The one predicate both the plain serve above and the card
    /// adoption below (#4591) decide by, so the two can never disagree about what a refetch is (L261).
    private func servesRefetch(_ onRefetch: Refetch, in store: ModelContainer) -> Bool {
        onRefetch == .serveWhenNothingChanged && !store.mainContext.hasChanges
            && !saves.hasForeignSaves(in: store)
    }

    /// #4252: serves a refetch. The refetch spent the tracking the build armed, so a new generation is armed
    /// on every stored property of every row, and on whatever `alsoTracked` reads (#4591: the cards adopted
    /// in the same breath), so no later edit to any of it is missed.
    private func rearm(_ fingerprint: ScopeFingerprint, alsoTracked: () -> Void) {
        let generation = staleFlag.arm()
        withObservationTracking {
            fingerprint.sources.armAll()
            alsoTracked()
        } onChange: { [staleFlag] in
            staleFlag.set(ifArmedAt: generation)
        }
        servedUnchanged += 1
    }

    private func held(_ wanted: Key, now: Date, staleAfter: Staleness) -> Value? {
        guard let key, key == wanted, let value, let builtAt,
              !staleAfter.hasExpired(builtAt: builtAt, now: now) else { return nil }
        return value
    }

    private func resolve(fingerprint: ScopeFingerprint,
                         cardKeys: Set<String>,
                         now: Date,
                         staleAfter: Staleness,
                         savesIn store: ModelContainer?,
                         build: () -> Value) -> Value {
        let wanted = Key(fingerprint: fingerprint.finalized(), cardKeys: cardKeys)
        let savesNow = store.map { saves.value(for: $0) }
        if let current = held(wanted, now: now, staleAfter: staleAfter), !staleFlag.isSet,
           savesAtBuild == savesNow {
            return current
        }
        return rebuild(wanted, rows: fingerprint.sources, now: now, savesNow: savesNow, build: build)
    }

    private func rebuild(_ wanted: Key, rows: ScopeRows, now: Date, savesNow: Int?, build: () -> Value) -> Value {
        var built: Value?
        let generation = staleFlag.arm()
        withObservationTracking {
            built = build()
        } onChange: { [staleFlag] in
            staleFlag.set(ifArmedAt: generation)
        }
        // `withObservationTracking` runs its `apply` closure synchronously and exactly once, so this is
        // set by the time control reaches here. Force unwrapped rather than defaulted, because a default
        // would turn a broken assumption into a plausible answer instead of a crash (L67).
        let result = built!
        builds += 1
        key = wanted
        keyRows = rows
        value = result
        builtAt = now
        savesAtBuild = savesNow
        return result
    }

}

/// #4570: a memoised answer that carries the pass's card store, which is what lets the memo decide the
/// card half of its own key (`ScopeMemo.value(fingerprint:drawn:...)`) for every surface from one implementation.
protocol CarriesCardStore {
    var cards: QueueModel.CardStore { get }
}

extension QueueModel.Scope: CarriesCardStore {}
extension QueueView.RenderData: CarriesCardStore {}

extension ScopeMemo where Value: CarriesCardStore {

    /// The answer for a surface whose pass carries a card store, given the keys the LAST FRAME DREW (drained
    /// from the registry by the caller, on every evaluation, as the header's part 3 requires). `build` is
    /// handed the card keys the pass must prebuild.
    ///
    /// The memo decides the card half of its own key here, one implementation for the queue and the Archive
    /// (L613), and both rules are about cards the held answer can serve with its tracking intact.
    ///
    /// 1. COVERED. Every drawn key was prebuilt by the build that made the held answer, so that build's key
    ///    set is the key and the answer is served: a frame drawing fewer rows than the last pass prebuilt
    ///    needs nothing new (#4106).
    ///
    /// 2. ADOPTED. Some drawn key was not prebuilt, so its card was built on demand during the render,
    ///    OUTSIDE the build's tracking. Rather than derive the whole store again to bring it inside, those
    ///    cards are built again inside tracking (`CardStore.adopt`) and counted as requested, so a field only
    ///    a card reads still marks the answer stale and the key holds still. #4570 did this for the first
    ///    frame of a mount alone. #4591 measured the two cases it left: shows arriving under a mounted queue,
    ///    where the save's refetch has marked the answer stale before the first frame's cards are asked for,
    ///    and a removal that reveals rows, whose cards the change's own pass could not have prebuilt. Each
    ///    derived the whole store a second time, reason `nothing this view reads`, and a scroll is the same
    ///    shape. A whole-store pass is the queue's 364 ms (2026-09-25); adopting is one card build per row
    ///    revealed.
    ///
    /// Adoption happens only into an answer this evaluation would otherwise SERVE: the same rows (the
    /// fingerprint, since building a card from a deleted model reads data that is gone), inside its window,
    /// no save since its build, and either unmarked or marked only by a refetch that changed nothing
    /// (`servesRefetch`). In the unmarked case the cards' tracking EXTENDS the build's generation; in the
    /// refetch case the refetch is served here and the cards are tracked in the same re-arm. Anything else
    /// derives, exactly as it always did.
    ///
    /// #4371: `shows` is the surface's live resolver, the one its rows draw their cards through, because an adopted
    /// card is built again the way its draw built it (a store over the models holds its shows by identity).
    func value(fingerprint: ScopeFingerprint,
               drawn: Set<String>,
               resolving shows: some ShowResolver,
               now: Date,
               staleAfter: Staleness = .seconds(ScopeMemo.staleAfterSeconds),
               savesIn store: ModelContainer,
               onRefetch: Refetch,
               build: (Set<String>) -> Value) -> Value {
        let keys = cardKeys(serving: drawn, resolving: shows, under: fingerprint, now: now, staleAfter: staleAfter,
                            savesIn: store, onRefetch: onRefetch)
        return value(fingerprint: fingerprint, cardKeys: keys, now: now, staleAfter: staleAfter,
                     savesIn: store, onRefetch: onRefetch) { build(keys) }
    }

    private func cardKeys(serving drawn: Set<String>, resolving shows: some ShowResolver,
                          under fingerprint: ScopeFingerprint, now: Date,
                          staleAfter: Staleness, savesIn store: ModelContainer,
                          onRefetch: Refetch) -> Set<String> {
        guard let key, let value, let prebuilt = value.cards.requestedKeys else { return drawn }
        if drawn.isSubset(of: prebuilt) { return prebuilt }
        guard key.fingerprint == fingerprint.finalized(), let builtAt,
              !staleAfter.hasExpired(builtAt: builtAt, now: now),
              savesAtBuild == saves.value(for: store) else { return drawn }
        let refetched = staleFlag.isSet
        if refetched && !servesRefetch(onRefetch, in: store) { return drawn }
        let revealed = drawn.subtracting(prebuilt)
        var adopted = false
        if refetched {
            rearm(fingerprint) { adopted = value.cards.adopt(revealed, resolving: shows) }
        } else {
            let generation = staleFlag.current
            withObservationTracking {
                adopted = value.cards.adopt(revealed, resolving: shows)
            } onChange: { [staleFlag] in
                staleFlag.set(ifArmedAt: generation)
            }
        }
        guard adopted else { return drawn }
        let widened = prebuilt.union(revealed)
        self.key = Key(fingerprint: key.fingerprint, cardKeys: widened)
        return widened
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
///
/// #4612: it hashes ADDRESSES, which are sound only while the objects behind them live, so the memo holds the rows
/// (`sources`) for as long as it holds the key. A memo is therefore handed the fingerprint itself, never the hash
/// alone.
struct ScopeFingerprint {
    private var hasher = Hasher()
    // #4252: the rows themselves, so a memo that serves a refetch can re-arm observation on every one of
    // them. Kept by the same `add` that hashes their identities, so a collection cannot be keyed without
    // also being re-armed.
    private(set) var sources = ScopeRows()

    init() {}

    mutating func add<Element: ScopeObserved>(_ items: [Element]) {
        // The count is combined as well as the members, so two adjacent inputs cannot trade an element
        // and leave the running hash identical.
        hasher.combine(items.count)
        for item in items { hasher.combine(ObjectIdentifier(item)) }
        sources.add(items)
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
///
/// #4252: GENERATIONS, because a memo that served a refetch has tracking armed on EVERY stored property,
/// and when a later build replaces it, that tracking cannot be cancelled with supported API. Without this,
/// a later change to a property only the served re-arm watched (one the build never reads) would mark the
/// build's answer stale. Each arming clears the flag and hands back a generation; only the tracking armed
/// last may set it.
final class StaleFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = true
    private var generation = 0

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    /// Clears the flag and starts a new generation of tracking.
    func arm() -> Int {
        lock.lock(); defer { lock.unlock() }
        flag = false
        generation += 1
        return generation
    }

    /// #4570: the generation the latest `arm()` started, WITHOUT starting a new one, for tracking that
    /// EXTENDS what the build armed rather than replacing it (`ScopeMemo.value(fingerprint:drawn:...)`). A new
    /// generation there would silence the build's own tracking, so a later edit only the build read would
    /// no longer mark the answer stale.
    var current: Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    /// Marks the answer stale, but only for tracking armed by the latest `arm()`.
    func set(ifArmedAt armed: Int) {
        lock.lock(); defer { lock.unlock() }
        if armed == generation { flag = true }
    }
}
