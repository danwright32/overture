import Foundation
import SwiftData

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
        return try copyPresent(plan(liveBase: liveBase, debugBase: debugBase), fileManager: fileManager)
    }

    // Shared copy loop for both the dev-data seed and the #325 Gmail seed: copy each present source
    // over any stale destination, report copied vs missing. The token file carries a real refresh
    // token, so it is tightened to owner-only (0600) on arrival, matching GmailCredentials.saveTokens.
    private static func copyPresent(_ items: [(name: String, src: URL, dest: URL)],
                                    fileManager: FileManager) throws -> (copied: [String], missing: [String]) {
        var copied: [String] = []
        var missing: [String] = []
        for item in items {
            guard fileManager.fileExists(atPath: item.src.path) else { missing.append(item.name); continue }
            if fileManager.fileExists(atPath: item.dest.path) { try fileManager.removeItem(at: item.dest) }
            try fileManager.copyItem(at: item.src, to: item.dest)
            if item.name == "gmail-tokens.json" {
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: item.dest.path)
            }
            copied.append(item.name)
        }
        return (copied, missing)
    }

    // #325: the Gmail credential files, copied as a SEPARATE opt-in action so the general dev-data
    // seed (inputFileNames) never carries credentials. gmail-oauth.json is the OAuth client config
    // and gmail-tokens.json holds the real refresh token.
    static let gmailFileNames = ["gmail-oauth.json", "gmail-tokens.json"]

    // Copy the live Gmail credential files into the isolated Overture-Debug handoff folder so the real
    // approve -> send -> success/error path can be driven end to end in a dev build (#267 otherwise
    // leaves the Debug build with no Gmail login). Sensitive: opt-in, DEBUG-gated, 0600 on the token.
    @discardableResult
    static func seedGmail(liveBase: URL, debugBase: URL,
                          fileManager: FileManager = .default) throws -> (copied: [String], missing: [String]) {
        try fileManager.createDirectory(at: debugBase, withIntermediateDirectories: true)
        let items = gmailFileNames.map { name in
            (name: name, src: liveBase.appendingPathComponent(name), dest: debugBase.appendingPathComponent(name))
        }
        return try copyPresent(items, fileManager: fileManager)
    }

    // The live handoff directory (Release data root), regardless of which build is running.
    static var liveHandoffDirectory: URL {
        StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    // The Debug build's isolated handoff directory.
    static var debugHandoffDirectory: URL {
        StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: true)
    }

    @discardableResult
    static func seedFromLive() throws -> (copied: [String], missing: [String]) {
        try seed(liveBase: liveHandoffDirectory, debugBase: debugHandoffDirectory)
    }

    // #325: copy the live Gmail credentials into the Debug folder so the dev build is connected.
    @discardableResult
    static func seedGmailFromLive() throws -> (copied: [String], missing: [String]) {
        try seedGmail(liveBase: liveHandoffDirectory, debugBase: debugHandoffDirectory)
    }

    // #318: the targeted-reset counterpart to seed. Removes the handoff INPUTS this helper manages
    // (only the inputFileNames set) from the Debug folder, returning the names actually removed.
    // Because it takes only the Debug base and touches only its own file set, it can never reach the
    // live folder, and it leaves the dev Gmail login (and any other stray dev file) intact.
    @discardableResult
    static func clearHandoffInputs(debugBase: URL,
                                   fileManager: FileManager = .default) throws -> [String] {
        var removed: [String] = []
        for name in inputFileNames {
            let url = debugBase.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try fileManager.removeItem(at: url)
            removed.append(name)
        }
        return removed
    }

    // Empty the dev store by deleting every model object (Prospect is the only @Model). Emptying the
    // contents in the running app is safe and immediate, unlike deleting the open store file on disk.
    static func clearStore(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        for p in all { context.delete(p) }
    }
}
#endif
