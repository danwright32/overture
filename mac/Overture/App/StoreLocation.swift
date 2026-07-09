import Foundation
import AppKit

// Where the local SwiftData store, its single-writer lockfile, and every other piece of Overture's
// on-disk state live (#264 / Phase 0 and #267 / Phase 3 of #237).
//
// Release (the resident /Applications copy): the data directory stays EXACTLY SwiftData's historical
// default (the Application Support root), so Dan's live prospects, Gmail token, and Downbeat export
// are never orphaned.
//
// Debug (a development run from Xcode): the data directory is an isolated `Overture-Debug` subfolder,
// and the bundle identity carries a `.debug` suffix (project.yml). Together these guarantee a dev run
// can never share a store/WAL (or a TCC grant, Gmail login, or export file) with the resident copy.
//
// The Debug/Release decision is factored into a pure function so both branches are testable from the
// (always-Debug) test bundle; the live build wires `#if DEBUG` to it.
enum StoreLocation {
    #if DEBUG
    static let isDebugBuild = true
    #else
    static let isDebugBuild = false
    #endif

    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    // Pure and testable: given the Application Support root and whether this is a Debug build, returns
    // the directory Overture keeps all of its on-disk state in. Release is the root (unchanged);
    // Debug is an isolated subfolder.
    static func dataDirectory(appSupport: URL, isDebugBuild: Bool) -> URL {
        isDebugBuild ? appSupport.appendingPathComponent("Overture-Debug", isDirectory: true) : appSupport
    }

    // The live data directory for THIS build. Creates the Debug subfolder on first use (the Release
    // root always exists); every on-disk path in the app hangs off this so dev and resident never mix.
    static var dataDirectory: URL {
        let dir = dataDirectory(appSupport: appSupport, isDebugBuild: isDebugBuild)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var storeURL: URL { dataDirectory.appendingPathComponent("default.store") }
    static var lockURL: URL { dataDirectory.appendingPathComponent("default.store.lock") }

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

    // The single source of truth for the handoff directory: the "Overture" subfolder of the data
    // directory, where every cross-boundary JSON file the app reads or writes lives (docs/contracts.md).
    // Pure and testable, mirroring dataDirectory; every call site must derive its path from this so a
    // file can never silently land outside the Debug/Release split (#317).
    static func handoffDirectory(appSupport: URL, isDebugBuild: Bool) -> URL {
        dataDirectory(appSupport: appSupport, isDebugBuild: isDebugBuild)
            .appendingPathComponent("Overture", isDirectory: true)
    }

    // The handoff directory for THIS build. Creates it on first use (dataDirectory already ensures the
    // parent exists), so writers never hit a missing-directory error.
    static var handoffDirectory: URL {
        let dir = handoffDirectory(appSupport: appSupport, isDebugBuild: isDebugBuild)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
