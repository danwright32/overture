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

    // #666: StoreUnavailableView's degraded-state warning names a file path in prose, with nothing
    // to click; this is the reveal action behind its "Show in Finder" button. Mirrors
    // AgentLogLocation.revealInFinder's injected-opener convention so it's unit-testable without
    // launching Finder.
    @Test func revealStoreOpensTheStoreFileWhenItExists() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = base.appendingPathComponent("default.store")
        try Data("x".utf8).write(to: store)

        var opened: URL?
        let returned = StoreLocation.revealStoreInFinder(storeURL: store, open: { opened = $0 })

        #expect(opened == store)
        #expect(returned == store)
    }

    // A not-yet-created store (a fresh install, or the #663 refusal before anything's written) must
    // still open Finder somewhere useful, not silently do nothing.
    @Test func revealStoreOpensTheContainingFolderWhenTheStoreIsMissing() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = base.appendingPathComponent("default.store")   // never created

        var opened: URL?
        let returned = StoreLocation.revealStoreInFinder(storeURL: store, open: { opened = $0 })

        #expect(opened == base)
        #expect(returned == base)
    }

    // #317: the handoff directory (where every cross-boundary JSON file lives) is the "Overture"
    // subfolder of the data directory, derived through one helper so it cannot drift per-call-site.
    @Test func handoffDirectoryIsTheOvertureSubfolderInRelease() {
        let dir = StoreLocation.handoffDirectory(appSupport: appSupport, isDebugBuild: false)
        #expect(dir == appSupport.appendingPathComponent("Overture", isDirectory: true))
    }

    @Test func handoffDirectoryIsIsolatedInDebug() {
        // The Debug build's handoff files must live UNDER Overture-Debug, never the live folder.
        let dir = StoreLocation.handoffDirectory(appSupport: appSupport, isDebugBuild: true)
        #expect(dir == appSupport.appendingPathComponent("Overture-Debug", isDirectory: true)
            .appendingPathComponent("Overture", isDirectory: true))
    }

    @Test func handoffDirectorySitsUnderTheDataDirectory() {
        for isDebug in [true, false] {
            let data = StoreLocation.dataDirectory(appSupport: appSupport, isDebugBuild: isDebug)
            let handoff = StoreLocation.handoffDirectory(appSupport: appSupport, isDebugBuild: isDebug)
            #expect(handoff.deletingLastPathComponent() == data)
        }
    }

    // Regression for the #317 leak: the two reply-classify files used to build their path from the
    // raw application-support root, bypassing StoreLocation, so a Debug run wrote them to the LIVE
    // folder. They must now resolve under the (this-build) handoff directory like every other file.
    @Test func replyClassifyFilesResolveUnderTheHandoffDirectory() {
        #expect(ReplyClassifyQueueBuilder.defaultURL.deletingLastPathComponent() == StoreLocation.handoffDirectory)
        #expect(ReplyClassifyResultsDecoder.defaultURL.deletingLastPathComponent() == StoreLocation.handoffDirectory)
    }
}
