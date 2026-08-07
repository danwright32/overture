import Foundation
import Darwin
import SwiftData

// Shared by every real (not source-scan) save-failure test (#617). Builds a genuinely-immutable
// on-disk SwiftData store so a save from a FRESH container against it throws for real: see
// ModelContextSaveOrWarnTests for why chflags on an already-open container's OWN store does NOT
// work (its already-open file handle bypasses the check), and why an in-memory store's
// unique-constraint duplicate insert does not reliably throw either.
@MainActor
enum ImmutableStoreFixture {
    // #1608: the two things whose ORDER was the defect. Recorded only while a test is watching, because
    // the ordering has no other observable consequence: both orders leave the caller seeing a torn-down
    // fixture, and the difference is only visible to whatever runs NEXT. See ImmutableStoreFixtureTests.
    enum Step: Equatable { case toreDown, releasedLock }
    static var stepsForTesting: [Step]?

    private static func note(_ step: Step) {
        if stepsForTesting != nil { stepsForTesting?.append(step) }
    }

    // `seed` runs against a first, disposable container to create the on-disk store with whatever
    // starting content the test needs, which is then flagged immutable. `body` receives a FRESH
    // context backed by that immutable store, so its own save() call genuinely fails.
    // #1006: every real (URL-backed) ModelContainer here runs between an acquire()/release() pair
    // so this fixture's container creation and saves never overlap another suite's, in the whole
    // process. Inline acquire/do/catch/release, not a closure-taking wrapper: `body` and `seed`
    // capture MainActor-isolated caller state that legitimately isn't Sendable, and Swift 6 flags
    // sending that into ANY function whose own isolation isn't provably the same as the caller's,
    // wrapper or not. `acquire`/`release` take no payload, so only those two hops actually cross.
    static func withFailingSave<T>(
        schema: Schema,
        seed: (ModelContext) throws -> Void,
        body: (ModelContext) async throws -> T
    ) async throws -> T {
        await RealStoreTestLock.shared.acquire()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("immutable-store-\(UUID().uuidString)", isDirectory: true)
        let storeURL = dir.appendingPathComponent("default.store")
        // #1608: the tear-down, and the ORDER it happens in relative to the lock, is the whole of that
        // issue. It used to sit in a `defer` inside the do-block, and a `defer` unwinds on the way OUT of
        // the scope, which is after `release()` on the success path. So the immutable flags were still
        // set, the temp directory was still there, and both containers were still alive and holding
        // SwiftData store coordinators, at the moment the next suite was allowed to start.
        //
        // What Dan saw was roughly one run in five failing with
        // `SwiftData.DefaultStore save failed ... "you don't have permission"` naming a path under
        // `/var/folders/.../immutable-store-<UUID>/default.store`, in a DIFFERENT suite each time, and
        // passing on the identical retry. That path is this fixture's, and the permission error is what
        // this fixture DELIBERATELY causes: it was leaking into whatever ran next.
        //
        // Since #1347 the local suite is the only thing verifying the Mac app before a merge, so a gate
        // that fails at random trains the operator to re-run until green, which is exactly how a real
        // regression gets waved through.
        func tearDown() {
            for suffix in ["", "-wal", "-shm"] { _ = chflags(storeURL.path + suffix, 0) }
            try? FileManager.default.removeItem(at: dir)
            note(.toreDown)
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // The containers live inside this inner scope ONLY, so they and their coordinators are gone
            // before the flags come off and long before the lock is released.
            let result: T = try await {
                let seedContext = ModelContext(try ModelContainer(
                    for: schema, configurations: [ModelConfiguration(url: storeURL)]))
                try seed(seedContext)
                try seedContext.save()

                for suffix in ["", "-wal", "-shm"] {
                    _ = chflags(storeURL.path + suffix, UInt32(UF_IMMUTABLE))
                }

                let context = ModelContext(try ModelContainer(
                    for: schema, configurations: [ModelConfiguration(url: storeURL)]))
                return try await body(context)
            }()
            tearDown()
            await RealStoreTestLock.shared.release()
            note(.releasedLock)
            return result
        } catch {
            tearDown()
            await RealStoreTestLock.shared.release()
            note(.releasedLock)
            throw error
        }
    }
}
