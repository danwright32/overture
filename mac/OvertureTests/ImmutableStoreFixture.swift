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
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("immutable-store-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let storeURL = dir.appendingPathComponent("default.store")
            defer {
                for suffix in ["", "-wal", "-shm"] { _ = chflags(storeURL.path + suffix, 0) }
                try? FileManager.default.removeItem(at: dir)
            }

            let seedContext = ModelContext(try ModelContainer(
                for: schema, configurations: [ModelConfiguration(url: storeURL)]))
            try seed(seedContext)
            try seedContext.save()

            for suffix in ["", "-wal", "-shm"] {
                _ = chflags(storeURL.path + suffix, UInt32(UF_IMMUTABLE))
            }

            let context = ModelContext(try ModelContainer(
                for: schema, configurations: [ModelConfiguration(url: storeURL)]))
            let result = try await body(context)
            await RealStoreTestLock.shared.release()
            return result
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
