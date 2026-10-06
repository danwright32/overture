import Testing
import Foundation

// #4338 (A10): the Debug build opened on a NAMED folder (`run-debug.sh --store-folder`), so a synthetic store
// can be looked at without overwriting the Debug store and with no route to the live one. The shell refuses
// first; this is the app's own refusal, so a launch by hand with the argument is refused too. Every case
// works in a sandbox standing in for Application Support, never the real one.
@Suite("Debug store folder (#4338)")
final class DebugStoreFolderTests {
    private let sandboxes = TemporarySandboxes()

    private func layout() throws -> (appSupport: URL, scratch: URL) {
        let root = try sandboxes.make(named: "debug-store-folder")
        let appSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        let fm = FileManager.default
        for name in ["Overture/inner", "Overture-Debug/inner"] {
            try fm.createDirectory(at: appSupport.appendingPathComponent(name, isDirectory: true),
                                   withIntermediateDirectories: true)
        }
        let scratch = root.appendingPathComponent("scratch store", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        return (appSupport, scratch)
    }

    private func folder(_ path: String, appSupport: URL, debug: Bool = true) -> StoreLocation.DebugStoreFolder {
        StoreLocation.debugStoreFolder(arguments: ["Overture", StoreLocation.storeFolderArgument, path],
                                       isDebugBuild: debug, appSupport: appSupport)
    }

    private func isRefused(_ answer: StoreLocation.DebugStoreFolder) -> Bool {
        if case .refused = answer { return true }
        return false
    }

    @Test func aNamedScratchFolderIsOpened() throws {
        let (appSupport, scratch) = try layout()
        let answer = folder(scratch.path, appSupport: appSupport)
        #expect(answer == .folder(scratch.resolvingSymlinksInPath().standardizedFileURL))
    }

    @Test func noArgumentLeavesTheBuildsOwnFolder() throws {
        let (appSupport, _) = try layout()
        #expect(StoreLocation.debugStoreFolder(arguments: ["Overture"], isDebugBuild: true,
                                               appSupport: appSupport) == .notAsked)
    }

    // A Release build never reads the argument at all: it opens the live store and nothing else.
    @Test func aReleaseBuildIgnoresTheArgument() throws {
        let (appSupport, scratch) = try layout()
        #expect(folder(scratch.path, appSupport: appSupport, debug: false) == .notAsked)
    }

    @Test func theLiveReleaseFolderIsRefused() throws {
        let (appSupport, _) = try layout()
        let live = StoreLocation.dataDirectory(appSupport: appSupport, isDebugBuild: false)
        #expect(isRefused(folder(live.path, appSupport: appSupport)))
        #expect(isRefused(folder(live.appendingPathComponent("inner").path, appSupport: appSupport)))
    }

    @Test func theDefaultDebugFolderIsRefused() throws {
        let (appSupport, _) = try layout()
        let debug = StoreLocation.dataDirectory(appSupport: appSupport, isDebugBuild: true)
        #expect(isRefused(folder(debug.path, appSupport: appSupport)))
        #expect(isRefused(folder(debug.appendingPathComponent("inner").path, appSupport: appSupport)))
    }

    // Application Support holds both folders, so a store there would put its handoff folder on the live one.
    @Test func aFolderHoldingEitherIsRefused() throws {
        let (appSupport, _) = try layout()
        #expect(isRefused(folder(appSupport.path, appSupport: appSupport)))
        #expect(isRefused(folder(appSupport.deletingLastPathComponent().path, appSupport: appSupport)))
    }

    @Test func aLinkToTheLiveFolderIsRefusedAsThatFolder() throws {
        let (appSupport, scratch) = try layout()
        let link = scratch.deletingLastPathComponent().appendingPathComponent("link-to-live")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: StoreLocation.dataDirectory(appSupport: appSupport, isDebugBuild: false))
        #expect(isRefused(folder(link.path, appSupport: appSupport)))
    }

    @Test func aMissingOrRelativeFolderIsRefused() throws {
        let (appSupport, scratch) = try layout()
        #expect(isRefused(folder(scratch.appendingPathComponent("not-made").path, appSupport: appSupport)))
        #expect(isRefused(folder("scratch store", appSupport: appSupport)))
        #expect(isRefused(StoreLocation.debugStoreFolder(arguments: ["Overture", StoreLocation.storeFolderArgument],
                                                          isDebugBuild: true, appSupport: appSupport)))
    }

    // The folder's own data directory, store and handoff folder, laid out as the Debug build lays out its own.
    @Test func aScratchFolderHoldsTheStoreAndItsHandoffFolder() throws {
        let (_, scratch) = try layout()
        let paths = StoreLocation.paths(inStoreFolder: scratch)
        #expect(paths.store == scratch.appendingPathComponent(StoreLocation.storeFilename))
        #expect(paths.handoff == scratch.appendingPathComponent("Overture", isDirectory: true))
    }

    // The flag `run-debug.sh` hands the app is the one the app reads, compared across the two files (L70): a
    // rename on either side would open the Debug store while the script printed the named one.
    @Test func theFlagRunDebugHandsIsTheOneTheAppReads() throws {
        let script = try String(contentsOf: RepoRoot.mac.appendingPathComponent("scripts/run-debug.sh"), encoding: .utf8)
        #expect(script.contains("\"\(StoreLocation.storeFolderArgument)\""),
                "run-debug.sh hands a store folder flag the app does not read")
    }
}
