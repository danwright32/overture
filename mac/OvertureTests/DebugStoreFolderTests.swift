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
        // The top of the disk holds everything; a comparison of path text read it as `//` and opened it.
        #expect(isRefused(folder("/", appSupport: appSupport)))
    }

    @Test func aLinkToTheLiveFolderIsRefusedAsThatFolder() throws {
        let (appSupport, scratch) = try layout()
        let link = scratch.deletingLastPathComponent().appendingPathComponent("link-to-live")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: StoreLocation.dataDirectory(appSupport: appSupport, isDebugBuild: false))
        #expect(isRefused(folder(link.path, appSupport: appSupport)))
    }

    // The startup volume ignores letter case, so a path in other letters names the same folder. The refusal
    // compares the folders themselves, device and inode, never the spelling (the review of ed57113). The
    // `#require` checks the premise: on a volume that respects case these spellings name nothing, and each
    // refusal below would then pass for that reason alone.
    private func otherLetters(_ appSupport: URL) throws -> URL {
        let cased = appSupport.deletingLastPathComponent().appendingPathComponent("application support", isDirectory: true)
        try #require(FileManager.default.fileExists(atPath: cased.appendingPathComponent("overture/inner").path),
                     "this volume respects letter case, so the spellings in this test name no folder")
        return cased
    }

    @Test func theLiveFolderSpelledInOtherLettersIsRefused() throws {
        let (appSupport, _) = try layout()
        let cased = try otherLetters(appSupport)
        #expect(isRefused(folder(cased.appendingPathComponent("overture").path, appSupport: appSupport)))
        #expect(isRefused(folder(cased.path, appSupport: appSupport)))
        let live = StoreLocation.dataDirectory(appSupport: appSupport, isDebugBuild: false)
        #expect(isRefused(folder(live.path, appSupport: cased)))
    }

    @Test func aFolderInsideTheLiveOneSpelledInOtherLettersIsRefused() throws {
        let (appSupport, _) = try layout()
        let cased = try otherLetters(appSupport)
        #expect(isRefused(folder(cased.appendingPathComponent("OVERTURE/inner").path, appSupport: appSupport)))
    }

    @Test func theDebugFolderSpelledInOtherLettersIsRefused() throws {
        let (appSupport, _) = try layout()
        let cased = try otherLetters(appSupport)
        #expect(isRefused(folder(cased.appendingPathComponent("overture-debug").path, appSupport: appSupport)))
        #expect(isRefused(folder(cased.appendingPathComponent("overture-debug/INNER").path, appSupport: appSupport)))
    }

    // Before the live folder exists, the folder that would hold it is still refused however Application Support
    // is spelled, and a scratch folder beside it is still opened. Foundation leaves the text of a path that does
    // not exist exactly as typed, so this is the spelling a comparison of path text cannot see.
    @Test func theFolderThatWouldHoldTheLiveOneIsRefusedBeforeItExists() throws {
        let root = try sandboxes.make(named: "debug-store-folder-empty")
        let empty = root.appendingPathComponent("Empty Support", isDirectory: true)
        let scratch = root.appendingPathComponent("scratch store", isDirectory: true)
        for made in [empty, scratch] {
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        }
        let cased = root.appendingPathComponent("empty support", isDirectory: true)
        try #require(FileManager.default.fileExists(atPath: cased.path),
                     "this volume respects letter case, so the spelling in this test names no folder")
        #expect(isRefused(folder(empty.path, appSupport: empty)))
        #expect(isRefused(folder(empty.path, appSupport: cased)))
        #expect(folder(scratch.path, appSupport: cased) == .folder(scratch.resolvingSymlinksInPath().standardizedFileURL))
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
