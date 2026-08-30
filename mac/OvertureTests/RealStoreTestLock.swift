import Foundation

// #1006: `main`'s swift-tests job crashed twice (not an assertion failure) with a SwiftData
// "PersistentIdentifier ... was remapped to a temporary identifier during save: This is a fatal
// logic error in DefaultStore" signature, always around a real, disk-backed ModelContainer save.
// Swift Testing runs suites concurrently by default. That sentence is TRUE of `swift test` and was
// never true of this suite: both testables in the scheme carry `parallelizable = "NO"`, which is what
// xcodegen writes when `mac/project.yml` says nothing, and it has said nothing since 5732781a. So what
// actually stopped the #1006 crash was the serial scheme, and this lock has been belt to that braces
// for as long as it has existed (measured 2026-08-30, #3234).
//
// It is not therefore decoration. It is what will keep these suites safe the moment parallel testing is
// turned on, which is #3266's business rather than this file's, and it is the only thing standing
// between them and the race below at that point. Do not remove it on the grounds that the suite is
// serial today.
//
// This crash shape is CoreData's own
// store-coordinator bookkeeping racing across containers built at the same moment, even when each
// points at its own unique on-disk file. `.serialized` only orders tests WITHIN one suite, so it
// can't fix a race ACROSS suites (WatchlistSeedTests, ImmutableStoreFixture's callers,
// RecipientBackfillLiveStoreTests, StoreSchemaGuardTests, LaunchMigrationsTests all build a
// URL-backed ModelContainer). Every one of those tests instead runs its container/save work
// through this single, process-wide FIFO lock, so at most one such critical section executes at
// a time no matter how many suites Swift Testing schedules concurrently.
//
// Deliberately NOT a closure-taking `run(_:)`: some real-store test suites are `@MainActor`
// (WatchlistSeedTests, ImmutableStoreFixture's callers) and some are plain, non-isolated structs
// (RecipientBackfillLiveStoreTests, StoreSchemaGuardTests, LaunchMigrationsTests) — that split
// isolation is exactly how the two groups can build a real ModelContainer at the same wall-clock
// moment despite never sharing a file. Wrapping a caller's closure (which, for the MainActor
// callers, captures MainActor-isolated test state) and sending it into this actor requires that
// closure and its result to be `Sendable`, which they legitimately aren't, and Swift 6 flags that
// even through a `nonisolated` method. `acquire`/`release` take no payload, so nothing ever needs
// to cross as Sendable: each caller wraps its OWN existing body in an ordinary `do`/`catch`,
// entirely within its own isolation context.
actor RealStoreTestLock {
    static let shared = RealStoreTestLock()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Waits until no other caller holds the lock, then takes it. Must be paired with `release()`
    /// on every exit path (including a throw) of the caller's critical section.
    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Releases the lock, waking the next FIFO waiter if there is one.
    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}
