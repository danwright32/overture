import Testing
import Foundation

// The one-time move of the live store off the shared Application Support root and onto a path only
// Overture uses. The root is SwiftData's plain default, so every unsandboxed SwiftData app on the
// Mac lands on the same `default.store` unless it says otherwise: Downbeat overwrote Overture's
// store there on 2026-07-08, and /usr/libexec/icloudmailagent migrated its own Core Data model onto
// it on 2026-07-23, dropping every Overture table. Moving to an Overture-only folder AND an
// Overture-only filename makes both impossible.
//
// The migration runs before the store is opened, so it has to be exactly as careful as the #663
// guard it borrows: move the legacy file only when it is genuinely Overture's, and when it is NOT,
// refuse loudly rather than let the app come up on a brand new empty store and read as total data
// loss to Dan.
@Suite("Store relocation off the shared path")
struct StoreRelocationTests {
    private func makeSandbox() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("relocation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    // A fresh install has neither file. Nothing to move, and nothing should be created.
    @Test func freshInstallNeedsNoMigration() throws {
        let base = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent("default.store")
        let new = base.appendingPathComponent("Overture/Overture.store")

        let outcome = StoreRelocation.migrate(legacyStoreURL: legacy, newStoreURL: new,
                                              isOvertureStore: { _ in true })

        #expect(outcome == .notNeeded)
        #expect(!FileManager.default.fileExists(atPath: new.path))
    }

    // The whole point: Dan's real store moves, and its WAL sidecars move with it under the new name.
    // A store separated from its -wal loses every transaction the WAL still holds.
    @Test func movesTheLegacyStoreAndItsSidecars() throws {
        let base = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent("default.store")
        let new = base.appendingPathComponent("Overture/Overture.store")
        try write("store", to: legacy)
        try write("wal", to: base.appendingPathComponent("default.store-wal"))
        try write("shm", to: base.appendingPathComponent("default.store-shm"))

        let outcome = StoreRelocation.migrate(legacyStoreURL: legacy, newStoreURL: new,
                                              isOvertureStore: { _ in true })

        #expect(outcome == .migrated)
        #expect(try String(data: Data(contentsOf: new), encoding: .utf8) == "store")
        #expect(try String(data: Data(contentsOf: base.appendingPathComponent("Overture/Overture.store-wal")),
                           encoding: .utf8) == "wal")
        #expect(try String(data: Data(contentsOf: base.appendingPathComponent("Overture/Overture.store-shm")),
                           encoding: .utf8) == "shm")
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    // A cleanly checkpointed store has no -shm. Its absence must not abort the move.
    @Test func movesAStoreThatHasNoSidecars() throws {
        let base = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent("default.store")
        let new = base.appendingPathComponent("Overture/Overture.store")
        try write("store", to: legacy)

        let outcome = StoreRelocation.migrate(legacyStoreURL: legacy, newStoreURL: new,
                                              isOvertureStore: { _ in true })

        #expect(outcome == .migrated)
        #expect(FileManager.default.fileExists(atPath: new.path))
    }

    // THE incident, exactly: another app's database is sitting at the legacy path. Moving it would
    // carry the foreign file onto Overture's new path and defeat the #663 guard, and ignoring it
    // silently would open a brand new empty store. Refuse, and name both paths in the reason.
    @Test func refusesToMoveAForeignStore() throws {
        let base = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent("default.store")
        let new = base.appendingPathComponent("Overture/Overture.store")
        try write("someone else's database", to: legacy)

        let outcome = StoreRelocation.migrate(legacyStoreURL: legacy, newStoreURL: new,
                                              isOvertureStore: { _ in false })

        guard case let .blocked(reason) = outcome else {
            Issue.record("expected a blocked outcome, got \(outcome)")
            return
        }
        #expect(reason.contains(legacy.path))
        #expect(!FileManager.default.fileExists(atPath: new.path))
        #expect(try String(data: Data(contentsOf: legacy), encoding: .utf8) == "someone else's database")
    }

    // Once Dan is on the new path, a foreign file reappearing at the old one is no longer Overture's
    // problem: the app already has its data and must start normally, not refuse.
    @Test func ignoresTheLegacyPathOnceTheNewStoreExists() throws {
        let base = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent("default.store")
        let new = base.appendingPathComponent("Overture/Overture.store")
        try FileManager.default.createDirectory(at: new.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try write("mine", to: new)
        try write("someone else's database", to: legacy)

        let outcome = StoreRelocation.migrate(legacyStoreURL: legacy, newStoreURL: new,
                                              isOvertureStore: { _ in false })

        #expect(outcome == .notNeeded)
        #expect(try String(data: Data(contentsOf: new), encoding: .utf8) == "mine")
    }

    // Assume it runs twice. A second pass must be a no-op, never overwriting the store it just moved
    // with a stale copy left at the old path.
    @Test func runningTwiceNeverClobbersTheMovedStore() throws {
        let base = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent("default.store")
        let new = base.appendingPathComponent("Overture/Overture.store")
        try write("real data", to: legacy)

        #expect(StoreRelocation.migrate(legacyStoreURL: legacy, newStoreURL: new,
                                        isOvertureStore: { _ in true }) == .migrated)
        try write("a stale leftover", to: legacy)
        let second = StoreRelocation.migrate(legacyStoreURL: legacy, newStoreURL: new,
                                             isOvertureStore: { _ in true })

        #expect(second == .notNeeded)
        #expect(try String(data: Data(contentsOf: new), encoding: .utf8) == "real data")
    }

    // A move that cannot complete must say so rather than report success and leave the app to open
    // nothing. Simulated by making the destination folder path a FILE, so creating it fails.
    @Test func reportsAFailedMoveInsteadOfClaimingSuccess() throws {
        let base = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent("default.store")
        try write("real data", to: legacy)
        let blocker = base.appendingPathComponent("Overture")
        try write("not a directory", to: blocker)
        let new = blocker.appendingPathComponent("Overture.store")

        let outcome = StoreRelocation.migrate(legacyStoreURL: legacy, newStoreURL: new,
                                              isOvertureStore: { _ in true })

        guard case .blocked = outcome else {
            Issue.record("expected a blocked outcome, got \(outcome)")
            return
        }
        #expect(try String(data: Data(contentsOf: legacy), encoding: .utf8) == "real data")
    }
}
