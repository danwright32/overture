import Foundation
import AppKit

// Where the local SwiftData store, its single-writer lockfile, and every other piece of Overture's
// on-disk state live (#264 / Phase 0 and #267 / Phase 3 of #237).
//
// Release (the resident /Applications copy): an `Overture` folder under Application Support, holding
// the store and the handoff files together.
//
// Debug (a development run from Xcode): an isolated `Overture-Debug` subfolder, and the bundle
// identity carries a `.debug` suffix (project.yml). Together these guarantee a dev run can never
// share a store/WAL (or a TCC grant, Gmail login, or export file) with the resident copy.
//
// Release used to sit directly in the Application Support ROOT, under SwiftData's own default
// filename, `default.store`. Both halves of that were defaults nobody chose, and both are shared:
// every unsandboxed SwiftData app on the Mac resolves to that same file unless it says otherwise.
// Twice it cost Dan his live store. Downbeat opened it on 2026-07-08, and on 2026-07-23
// /usr/libexec/icloudmailagent ran a Core Data lightweight migration onto it, replacing every
// Overture table with its own. Claiming an Overture-only FOLDER makes the collision impossible;
// claiming an Overture-only FILENAME means that even if something did write into that folder, it
// would arrive as `default.store` and miss Dan's data entirely. StoreRelocation performs the
// one-time move, and StoreSchemaGuard (#663) is what caught the collision both times.
//
// The Debug/Release decision is factored into a pure function so both branches are testable from the
// (always-Debug) test bundle; the live build wires `#if DEBUG` to it.
enum StoreLocation {
    #if DEBUG
    static let isDebugBuild = true
    #else
    static let isDebugBuild = false
    #endif

    // Overture's own store filename, deliberately NOT SwiftData's `default.store`. See above.
    static let storeFilename = "Overture.store"

    // What the store was called, and where it sat, before the move. Read only by StoreRelocation.
    static let legacyStoreFilename = "default.store"

    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    // Pure and testable: given the Application Support root and whether this is a Debug build, returns
    // the directory Overture keeps all of its on-disk state in. Each build claims a folder of its own,
    // and neither is the shared root.
    static func dataDirectory(appSupport: URL, isDebugBuild: Bool) -> URL {
        appSupport.appendingPathComponent(isDebugBuild ? "Overture-Debug" : "Overture", isDirectory: true)
    }

    // Pure variants of the live paths below, so both build branches are testable.
    static func storeURL(appSupport: URL, isDebugBuild: Bool) -> URL {
        dataDirectory(appSupport: appSupport, isDebugBuild: isDebugBuild)
            .appendingPathComponent(storeFilename)
    }

    static func lockURL(appSupport: URL, isDebugBuild: Bool) -> URL {
        storeURL(appSupport: appSupport, isDebugBuild: isDebugBuild)
            .appendingPathExtension("lock")
    }

    // Where this build's store sat before the move: Release in the shared Application Support root,
    // Debug in its own folder under the old filename.
    static func legacyStoreURL(appSupport: URL, isDebugBuild: Bool) -> URL {
        (isDebugBuild ? dataDirectory(appSupport: appSupport, isDebugBuild: true) : appSupport)
            .appendingPathComponent(legacyStoreFilename)
    }

    // The live data directory for THIS build. Creates the Debug subfolder on first use (the Release
    // root always exists); every on-disk path in the app hangs off this so dev and resident never mix.
    static var dataDirectory: URL {
        let dir = dataDirectory(appSupport: appSupport, isDebugBuild: isDebugBuild)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var storeURL: URL { dataDirectory.appendingPathComponent(storeFilename) }
    static var lockURL: URL { storeURL.appendingPathExtension("lock") }

    // The pre-move path for THIS build, used once at launch by StoreRelocation.
    static var legacyStoreURL: URL { legacyStoreURL(appSupport: appSupport, isDebugBuild: isDebugBuild) }

    // #666: reveal the store file in Finder so StoreUnavailableView's degraded-state warning is
    // directly actionable instead of leaving Dan to copy a path out of prose and paste it into
    // Finder by hand. Reveals the file itself, selected, when it exists; else its containing
    // directory, so the click still opens somewhere useful for a not-yet-created store (a fresh
    // install, or the #663 refusal before anything's written). The opener is injected, mirroring
    // AgentLogLocation.revealInFinder, so this is unit-testable without launching Finder.
    @discardableResult
    static func revealStoreInFinder(storeURL: URL = StoreLocation.storeURL,
                                    fileManager: FileManager = .default,
                                    open: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) -> URL {
        let target = fileManager.fileExists(atPath: storeURL.path) ? storeURL : storeURL.deletingLastPathComponent()
        open(target)
        return target
    }

    // The single source of truth for the handoff directory, where every cross-boundary JSON file the
    // app reads or writes lives (docs/contracts.md). Pure and testable, mirroring dataDirectory;
    // every call site must derive its path from this so a file can never silently land outside the
    // Debug/Release split (#317).
    //
    // In Release this IS the data directory, not a subfolder of it. That asymmetry is deliberate:
    // `~/Library/Application Support/Overture/` is a published contract, written into
    // docs/contracts.md, the prep and reply runbooks, import-history.ts and runner-setup.sh, and it
    // already pointed at this folder before the store moved into it. Moving the store here rather
    // than inventing a third folder left every one of those paths byte-identical, so the store move
    // could not break a runbook or a detached run. Debug keeps its own subfolder, unchanged.
    static func handoffDirectory(appSupport: URL, isDebugBuild: Bool) -> URL {
        let data = dataDirectory(appSupport: appSupport, isDebugBuild: isDebugBuild)
        return isDebugBuild ? data.appendingPathComponent("Overture", isDirectory: true) : data
    }

    // #2097: where a TEST run's handoff writes go instead.
    //
    // The handoff directory is not a scratch folder. It holds the Gmail tokens, the booking history and
    // every JSON file the scout, the app and the importer hand each other, and a test run reaching it
    // writes into Dan's live data. `HandoffCleanup` already carried a pin refusing to write there under
    // test, which meant the rule was understood and only partly enforced: any path not going through
    // that pin still landed in the real folder.
    //
    // Same shape as #2003's fix for the agent problem ledger, and for the same reason: applied where the
    // path is RESOLVED rather than at each call site, so a writer added later arrives protected instead
    // of needing to be remembered.
    //
    // Redirected rather than refused. A test exercising a real write path should still exercise it, and
    // a guard that silently dropped the write would leave the live folder looking exactly like one a
    // working guard protects (L11).
    //
    // A directory a test names ITSELF (a throwaway temp folder it then asserts on) is untouched: only
    // the computed live path is swapped, and the pure `handoffDirectory(appSupport:isDebugBuild:)` above
    // still answers for whatever it is handed.
    static var testRunHandoffDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-test-run-handoff", isDirectory: true)
    }

    static func writableHandoffDirectory(_ requested: URL,
                                         isUnderTest: Bool = AppEnvironment.isRunningUnderTests,
                                         testRunDirectory: URL = StoreLocation.testRunHandoffDirectory) -> URL {
        isUnderTest ? testRunDirectory : requested
    }

    // The handoff directory for THIS build. Creates it on first use (dataDirectory already ensures the
    // parent exists), so writers never hit a missing-directory error.
    static var handoffDirectory: URL {
        let dir = writableHandoffDirectory(handoffDirectory(appSupport: appSupport,
                                                            isDebugBuild: isDebugBuild))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
