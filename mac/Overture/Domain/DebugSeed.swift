import Foundation

// #281: a DEBUG-only test affordance. Phase 3 (#267) walls the Debug build off into its own
// Overture-Debug data directory, so a dev run starts empty and never sees the handoff files the
// external workflows write to the LIVE location. This copies the live handoff INPUTS (the files the
// app ingests) into the Debug folder, so scout/booking/reply can be exercised against realistic
// data without ever touching live data. Wrapped in #if DEBUG so it is compiled out of release
// builds entirely and can never run against Dan's real install.
#if DEBUG
enum DebugSeed {
    // The handoff files the app INGESTS (per docs/contracts.md): scout results, the Downbeat export,
    // booking/warm history, drafted emails, and reply intents, plus the optional blocked-dates
    // override. Deliberately excludes the files the app WRITES (prep/classify queues, voice
    // feedback) — copying those from live would clobber dev work product — and Gmail tokens
    // (out of scope, and sensitive).
    static let inputFileNames = [
        "downbeat-export.json",
        "overture-history.json",
        "overture-results.json",
        "overture-prep-results.json",
        "overture-reply-classify-results.json",
        "overture-blocked-dates.json",
    ]

    // The handoff subfolder under the data directory. Each domain file appends this itself today
    // (consolidation tracked in #317); kept here as one local constant for the seed.
    private static let handoffSubfolder = "Overture"

    // Pure: maps each input filename to a (source in live, dest in debug) pair under each base.
    static func plan(liveBase: URL, debugBase: URL) -> [(name: String, src: URL, dest: URL)] {
        inputFileNames.map { name in
            (name, liveBase.appendingPathComponent(name), debugBase.appendingPathComponent(name))
        }
    }

    // Copy every present input from live into the debug folder, overwriting any stale copy, and
    // report which were copied and which were absent in live.
    @discardableResult
    static func seed(liveBase: URL, debugBase: URL,
                     fileManager: FileManager = .default) throws -> (copied: [String], missing: [String]) {
        try fileManager.createDirectory(at: debugBase, withIntermediateDirectories: true)
        var copied: [String] = []
        var missing: [String] = []
        for item in plan(liveBase: liveBase, debugBase: debugBase) {
            guard fileManager.fileExists(atPath: item.src.path) else { missing.append(item.name); continue }
            if fileManager.fileExists(atPath: item.dest.path) { try fileManager.removeItem(at: item.dest) }
            try fileManager.copyItem(at: item.src, to: item.dest)
            copied.append(item.name)
        }
        return (copied, missing)
    }

    // The live handoff directory (Release data root), regardless of which build is running.
    static var liveHandoffDirectory: URL {
        StoreLocation.dataDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
            .appendingPathComponent(handoffSubfolder, isDirectory: true)
    }

    // The Debug build's isolated handoff directory.
    static var debugHandoffDirectory: URL {
        StoreLocation.dataDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: true)
            .appendingPathComponent(handoffSubfolder, isDirectory: true)
    }

    @discardableResult
    static func seedFromLive() throws -> (copied: [String], missing: [String]) {
        try seed(liveBase: liveHandoffDirectory, debugBase: debugHandoffDirectory)
    }
}
#endif
