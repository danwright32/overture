import Foundation

// Where the local SwiftData store and its single-writer lockfile live (#264 / Phase 0 of #237).
// CRITICAL: storeURL stays exactly SwiftData's historical default (Application Support/default.store)
// so the live prospect data is never orphaned. The Debug/Release store + bundle-id split (so a dev
// Xcode run can't share a WAL with the resident /Applications copy) is deferred to Phase 3 (#267),
// because doing it now would strand the daily Debug build's existing data before /Applications exists.
enum StoreLocation {
    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var storeURL: URL { appSupport.appendingPathComponent("default.store") }
    static var lockURL: URL { appSupport.appendingPathComponent("default.store.lock") }
}
