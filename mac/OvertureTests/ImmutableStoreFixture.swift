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
    static func withFailingSave<T>(
        schema: Schema,
        seed: (ModelContext) throws -> Void,
        body: (ModelContext) async throws -> T
    ) async throws -> T {
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
        return try await body(context)
    }
}
