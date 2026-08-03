import Testing
import Foundation

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

    @Test func releaseBuildUsesAnOvertureOnlyFolder() {
        let dir = StoreLocation.dataDirectory(appSupport: appSupport, isDebugBuild: false)
        #expect(dir == appSupport.appendingPathComponent("Overture", isDirectory: true))
    }

    @Test func debugBuildUsesAnIsolatedSubfolder() {
        let dir = StoreLocation.dataDirectory(appSupport: appSupport, isDebugBuild: true)
        #expect(dir == appSupport.appendingPathComponent("Overture-Debug", isDirectory: true))
    }

    // The regression guard for the two store-path collisions (Downbeat 2026-07-08, and Apple's
    // icloudmailagent 2026-07-23, which migrated its own Core Data model onto Overture's file and
    // dropped every table). NEITHER build may sit directly in the Application Support root: it is
    // shared by every unsandboxed app on the Mac, and each of them defaults to the same filename.
    @Test func neitherBuildSitsInTheSharedApplicationSupportRoot() {
        for isDebug in [true, false] {
            #expect(StoreLocation.dataDirectory(appSupport: appSupport, isDebugBuild: isDebug) != appSupport)
        }
    }

    // The second half of the same guard. `default.store` is what SwiftData names a store when the
    // app does not say otherwise, so it is exactly the name a colliding app arrives with. Overture's
    // store must not answer to it, in either build.
    @Test func theStoreIsNotNamedSwiftDatasDefault() {
        for isDebug in [true, false] {
            let store = StoreLocation.storeURL(appSupport: appSupport, isDebugBuild: isDebug)
            #expect(store.lastPathComponent == "Overture.store")
        }
    }

    @Test func releaseStoreLivesInTheOvertureFolder() {
        let store = StoreLocation.storeURL(appSupport: appSupport, isDebugBuild: false)
        #expect(store == appSupport.appendingPathComponent("Overture", isDirectory: true)
            .appendingPathComponent("Overture.store"))
    }

    // Where the store used to live, and therefore where the one-time migration reads from. Kept as
    // a named path rather than a literal at the call site so both builds move the right file.
    @Test func theLegacyStorePathIsTheOldSharedDefault() {
        #expect(StoreLocation.legacyStoreURL(appSupport: appSupport, isDebugBuild: false)
            == appSupport.appendingPathComponent("default.store"))
        #expect(StoreLocation.legacyStoreURL(appSupport: appSupport, isDebugBuild: true)
            == appSupport.appendingPathComponent("Overture-Debug", isDirectory: true)
                .appendingPathComponent("default.store"))
    }

    @Test func lockSitsBesideTheStoreInBothBuilds() {
        for isDebug in [true, false] {
            let store = StoreLocation.storeURL(appSupport: appSupport, isDebugBuild: isDebug)
            let lock = StoreLocation.lockURL(appSupport: appSupport, isDebugBuild: isDebug)
            #expect(store.deletingLastPathComponent() == lock.deletingLastPathComponent())
            #expect(lock.lastPathComponent == "Overture.store.lock")
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

    // Release's store folder and its handoff folder are deliberately the SAME folder. The handoff
    // path is a published cross-language contract (docs/contracts.md, the prep and reply runbooks,
    // import-history.ts, runner-setup.sh), so moving the store into it left every one of those paths
    // untouched. Debug keeps its handoff files in a subfolder, exactly where they already were.
    @Test func handoffDirectoryStaysWhereEveryContractSaysItIs() {
        let release = StoreLocation.handoffDirectory(appSupport: appSupport, isDebugBuild: false)
        #expect(release == StoreLocation.dataDirectory(appSupport: appSupport, isDebugBuild: false))

        let debug = StoreLocation.handoffDirectory(appSupport: appSupport, isDebugBuild: true)
        #expect(debug.deletingLastPathComponent()
            == StoreLocation.dataDirectory(appSupport: appSupport, isDebugBuild: true))
    }

    // The store file and the handoff JSON files share a folder in Release, so the store must not be
    // reachable under a name any handoff writer could produce.
    @Test func theStoreNameCannotCollideWithAHandoffFile() {
        let store = StoreLocation.storeURL(appSupport: appSupport, isDebugBuild: false)
        #expect(store.pathExtension == "store")
        #expect(!store.lastPathComponent.hasPrefix("overture-"))
    }

    // Regression for the #317 leak: the two reply-classify files used to build their path from the
    // raw application-support root, bypassing StoreLocation, so a Debug run wrote them to the LIVE
    // folder. They must now resolve under the (this-build) handoff directory like every other file.
    @Test func replyClassifyFilesResolveUnderTheHandoffDirectory() {
        #expect(ReplyClassifyQueueBuilder.defaultURL.deletingLastPathComponent() == StoreLocation.handoffDirectory)
        #expect(ReplyClassifyResultsDecoder.defaultURL.deletingLastPathComponent() == StoreLocation.handoffDirectory)
    }
}
