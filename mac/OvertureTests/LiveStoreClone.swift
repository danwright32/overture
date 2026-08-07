import Foundation

// #1672: the ONE way a test may read Dan's real store.
//
// Four suites rehearse a migration against real data, which is right: a migration that has only ever met
// fresh fixtures is a migration nobody has tried. Each did the same thing by hand, and two things about
// that were worth examining rather than inheriting.
//
// **The copy was not atomic, and the app is usually running.** The store, its `-wal` and its `-shm` were
// copied one at a time, with no checkpoint and no lock, while Overture Release may be actively writing. A
// store copied mid-write can land with a `-wal` that does not correspond to the `.store` beside it.
// SQLite may reject that, or recover it into a state different from the original, which would make a dry
// run's result a statement about a torn copy rather than about Dan's data. AGENTS.md already treats a WAL
// checkpoint as a required step when reading the live store by hand; the tests skipped it.
//
// So the clone is taken through SQLite's own ONLINE BACKUP, which is designed for exactly this: it reads
// a consistent snapshot of a database that is being written to, and it folds the WAL in as it goes. One
// file comes out, already checkpointed, with no `-wal` to correspond to anything.
//
// **Nothing structurally stopped a future test from opening the live file.** The rule lived in four
// repeated correct implementations and a comment. A test suite that can reach real user data should be
// structurally unable to write to it, not merely careful (L2). So this never hands back the live URL, and
// it refuses outright if the clone it is about to hand over is the live path.
//
// Deliberately NOT @MainActor. The live-store suites are split between MainActor ones and plain,
// non-isolated structs (the same split RealStoreTestLock's header records), and this only reads files and
// runs a subprocess, so it has no isolation of its own to impose on either group.
enum LiveStoreClone {
    enum Refusal: Error, CustomStringConvertible {
        case wouldHaveHandedOverTheLiveStore(String)
        case backupFailed(String)

        var description: String {
            switch self {
            case .wouldHaveHandedOverTheLiveStore(let path):
                return "LiveStoreClone was about to hand a test the LIVE store at \(path). Refused."
            case .backupFailed(let detail):
                return "LiveStoreClone could not take a consistent copy of the live store: \(detail). "
                    + "The dry run is skipped rather than run against a torn copy (#1672)."
            }
        }
    }

    /// The live Release store, or nil when this machine has none (a fresh clone, a CI runner).
    static var liveStoreURL: URL? {
        let url = StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A consistent clone of the live store inside `dir`, or nil when this machine has no live store,
    /// which is how every one of these suites already skips on a fresh clone or a CI runner.
    ///
    /// The caller owns `dir` and its clean-up, so each suite keeps the `defer` it already had and the only
    /// thing that moved is HOW the copy is taken.
    static func makeClone(in dir: URL) throws -> URL? {
        guard let live = liveStoreURL else { return nil }

        let clone = dir.appendingPathComponent("Overture.store")
        // The refusal, before anything opens anything. It can only fire if the directory handed in
        // resolves to the live store's own, which is exactly when a guard is worth having: the cost of
        // being wrong here is a test writing to the only copy of Dan's queue (L2).
        guard clone.standardizedFileURL.path != live.standardizedFileURL.path else {
            throw Refusal.wouldHaveHandedOverTheLiveStore(live.path)
        }

        try backUp(live, to: clone)
        return clone
    }

    /// SQLite's online backup, which is what makes the copy consistent rather than three files raced
    /// against a live writer.
    ///
    /// Shelled out to the `sqlite3` that ships with macOS rather than linking the C API into the test
    /// target, because the store is a plain SQLite database and this is a test-only read.
    ///
    /// A failure THROWS. It does not fall back to copying the three files: falling back would reintroduce
    /// the torn-copy risk this exists to remove, at the one moment there is evidence something is wrong,
    /// and a dry run against a torn copy answers a question nobody asked (L11).
    private static func backUp(_ live: URL, to clone: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [live.path, ".backup '\(clone.path)'"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            throw Refusal.backupFailed("could not run sqlite3: \(error)")
        }
        let stderrData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Refusal.backupFailed(String(data: stderrData, encoding: .utf8) ?? "exit \(process.terminationStatus)")
        }
        guard FileManager.default.fileExists(atPath: clone.path),
              (try? FileManager.default.attributesOfItem(atPath: clone.path)[.size] as? Int) ?? 0 > 0 else {
            throw Refusal.backupFailed("sqlite3 reported success but wrote no database")
        }
        // `.backup` preserves the SOURCE's journal mode, and the live store is in WAL. A WAL-mode database
        // with no `-shm` beside it cannot be opened READ-ONLY, because a read-only connection is not
        // allowed to create the shared-memory file it would need, and the readers here (StoreColumnCensus)
        // open read-only on purpose. So the clone is turned into a plain, self-contained database.
        //
        // That is also what makes "no sidecars" a real property rather than a trap: a snapshot missing the
        // files it depends on is worse than one that never needed them.
        try run(["\(clone.path)", "PRAGMA journal_mode=DELETE;"],
                failing: "could not make the clone self-contained")
    }

    private static func run(_ arguments: [String], failing what: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        do { try process.run() } catch { throw Refusal.backupFailed("\(what): \(error)") }
        let stderrData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Refusal.backupFailed("\(what): "
                + (String(data: stderrData, encoding: .utf8) ?? "exit \(process.terminationStatus)"))
        }
    }
}
