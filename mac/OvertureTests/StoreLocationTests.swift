import Testing
import Foundation
@testable import Overture

// #267 / Phase 3: the dev/real data split. The Xcode Debug build must resolve to its OWN data
// directory (and its own app identity) so a development run can never share a SwiftData store/WAL —
// or the Gmail token and Downbeat export — with the resident /Applications Release copy. The Release
// path must stay EXACTLY the historical default (Application Support root) so Dan's live data is not
// orphaned. The decision is factored into a pure function so both build branches are testable from
// the (always-Debug) test bundle.
@Suite("Store location split (#267)")
struct StoreLocationTests {
    private var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    @Test func releaseBuildKeepsTheLegacyApplicationSupportRoot() {
        // Changing this would strand Dan's existing prospects, Gmail login, and Downbeat export.
        #expect(StoreLocation.dataDirectory(appSupport: appSupport, isDebugBuild: false) == appSupport)
    }

    @Test func debugBuildUsesAnIsolatedSubfolder() {
        let dir = StoreLocation.dataDirectory(appSupport: appSupport, isDebugBuild: true)
        #expect(dir == appSupport.appendingPathComponent("Overture-Debug", isDirectory: true))
    }

    @Test func releaseStoreStaysAtTheHistoricalDefault() {
        let dir = StoreLocation.dataDirectory(appSupport: appSupport, isDebugBuild: false)
        #expect(dir.appendingPathComponent("default.store") == appSupport.appendingPathComponent("default.store"))
    }

    @Test func lockSitsBesideTheStoreInBothBuilds() {
        for isDebug in [true, false] {
            let dir = StoreLocation.dataDirectory(appSupport: appSupport, isDebugBuild: isDebug)
            let store = dir.appendingPathComponent("default.store")
            let lock = dir.appendingPathComponent("default.store.lock")
            #expect(store.deletingLastPathComponent() == lock.deletingLastPathComponent())
        }
    }
}
