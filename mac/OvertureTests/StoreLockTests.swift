import Testing
import Foundation
@testable import Overture

// #264 / Phase 0: the single-writer safety floor for #237. A flock on a lockfile beside the store is
// the REAL guard that two processes never open the same SwiftData file (not LaunchServices dedup).
// The store path must stay exactly the historical default so the live prospect data is never orphaned.
@Suite("Store lock (#264)")
struct StoreLockTests {
    private func tmpLock() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ovlock-\(UUID().uuidString).lock")
    }

    @Test func secondAcquireIsRefusedWhileTheFirstIsHeld() {
        let url = tmpLock()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = StoreLock.acquire(at: url)
        #expect(first != nil)
        #expect(StoreLock.acquire(at: url) == nil)   // a second "process" must be refused
        first?.release()
    }

    @Test func releasingLetsItBeReacquired() {
        let url = tmpLock()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = StoreLock.acquire(at: url)
        #expect(first != nil)
        first?.release()
        let again = StoreLock.acquire(at: url)
        #expect(again != nil)
        again?.release()
    }

    @Test func storePathMatchesTheLegacyDefaultSoDataIsNotOrphaned() {
        // The release store must remain Application Support/default.store (SwiftData's historical
        // default) — changing it would strand Dan's existing prospects. Debug/Release split is #267.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #expect(StoreLocation.storeURL == appSupport.appendingPathComponent("default.store"))
        #expect(StoreLocation.lockURL.deletingLastPathComponent() == StoreLocation.storeURL.deletingLastPathComponent())
    }
}
