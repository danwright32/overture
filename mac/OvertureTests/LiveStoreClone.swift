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
        return try clone(live, in: dir, named: "Overture.store")
    }

    // #2565: the dated LAUNCH backups of the live store, newest first.
    //
    // A migration rehearsed only against the store as it stands today is rehearsed against a store that
    // may already have healed: the rows #2508 lifted were corrected by an ordinary re-scout four days
    // after the issue was filed, so the live store no longer holds a single one of them, and a pass that
    // moves nothing there is indistinguishable from a pass that cannot move anything at all (L98). The
    // launch backups are the same real data on the days it was still wrong, and they are also the exact
    // state a restore puts back, which is the case the corrective pass exists for.
    //
    // Only the plain `yyyyMMdd-HHmmss` shape. A `.foreign` or `.unreadable` folder is NOT Dan's data
    // (#1410) and must never be read as though it were.
    static var launchBackupStores: [URL] {
        guard let live = liveStoreURL else { return [] }
        let dir = StoreBackup.backupsDirectory(dataDirectory: live.deletingLastPathComponent())
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { $0.range(of: #"^\d{8}-\d{6}$"#, options: .regularExpression) != nil }
            .sorted(by: >)
            .map { dir.appendingPathComponent($0).appendingPathComponent(StoreLocation.storeFilename) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A consistent clone of one of those backups inside `dir`, taken exactly as the live one is.
    ///
    /// `timeoutMilliseconds` is a seam and its default is the shipped value. It exists because the only
    /// way to watch the busy timeout DO anything is to contend for a lock on purpose, and a test that
    /// cannot ask for a different one can only assert that the default is written down (#3349, L3).
    static func makeClone(ofBackupAt backup: URL, in dir: URL,
                          timeoutMilliseconds: Int = busyTimeoutMilliseconds) throws -> URL {
        try clone(backup, in: dir, named: backup.deletingLastPathComponent().lastPathComponent + ".store",
                  timeoutMilliseconds: timeoutMilliseconds)
    }

    private static func clone(_ source: URL, in dir: URL, named name: String,
                              timeoutMilliseconds: Int = busyTimeoutMilliseconds) throws -> URL {
        let clone = dir.appendingPathComponent(name)
        // The refusal, before anything opens anything. It can only fire if the directory handed in
        // resolves to the source's own, which is exactly when a guard is worth having: the cost of being
        // wrong here is a test writing over the only copy of Dan's queue, or over the backup of it (L2).
        let forbidden = [source.standardizedFileURL.path,
                         liveStoreURL?.standardizedFileURL.path].compactMap { $0 }
        guard !forbidden.contains(clone.standardizedFileURL.path) else {
            throw Refusal.wouldHaveHandedOverTheLiveStore(source.path)
        }

        try backUp(source, to: clone, timeoutMilliseconds: timeoutMilliseconds)
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
    /// How long the backup waits for the source's lock before giving up, in milliseconds.
    ///
    /// #3349: without one, `sqlite3` returns SQLITE_BUSY on the FIRST contended attempt and the clone
    /// fails outright. Measured 2026-08-30 against a WAL database with the same sidecars the live store
    /// has, twelve concurrent `.backup` runs at a time: **six of twelve failed** with
    /// `Error: database is locked`, and with this timeout in place **none of twelve failed**.
    ///
    /// That is the same message a real run produced. On a full parallel run of the suite the only
    /// failure was `SameNightRoomVariantMergeLiveStoreTests`, with
    /// `LiveStoreClone.swift: Caught error: ... Error: database is locked`. Serially it never happened,
    /// because nothing else was cloning at the same moment.
    ///
    /// A timeout rather than a lock, and that is the point rather than an economy. Thirteen of the
    /// suites that clone never took `RealStoreTestLock`, and wrapping each of them would leave the rule
    /// as a convention repeated at every call site, which the next suite written is free to forget
    /// (L274, L96). It also covers the contention no test lock can reach: Dan's live app writing to the
    /// store while a suite clones it, which is the situation #1672 was built for in the first place.
    ///
    /// Thirty seconds because the wait is only ever paid under real contention and the alternative is a
    /// failed run. A clone of this store takes well under a second, so even every cloning suite starting
    /// at once queues far inside it, and exceeding it still FAILS loudly with the message above rather
    /// than falling back to a torn copy.
    static let busyTimeoutMilliseconds = 30_000

    /// The arguments that make the clone self-contained, built here for the same reason
    /// `backupArguments` is: so the pragma the shipped path actually runs is a value a test can read
    /// rather than a claim about the code (L3, L107).
    ///
    /// #3072: `WalCloneNeedsItsSidecarsTests` first re-typed this pragma into its own fixture, which
    /// measured SQLite correctly and guarded nothing here: a mutation replacing it with
    /// `PRAGMA user_version=1` left the suite green.
    static func selfContainedArguments(clone: URL) -> [String] {
        ["\(clone.path)", "PRAGMA journal_mode=DELETE;"]
    }

    /// The arguments for the online backup, built here rather than inline so the timeout the shipped
    /// path asks for is a value a test can read rather than a claim about the code (L3).
    static func backupArguments(source: URL, clone: URL, timeoutMilliseconds: Int) -> [String] {
        // `-cmd` runs before the argument that follows, so the timeout is in force when `.backup` opens
        // the source. Passing it afterwards would set it for a connection that has already failed.
        ["-cmd", ".timeout \(timeoutMilliseconds)", source.path, ".backup '\(clone.path)'"]
    }

    private static func backUp(_ live: URL, to clone: URL, timeoutMilliseconds: Int) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = backupArguments(source: live, clone: clone,
                                            timeoutMilliseconds: timeoutMilliseconds)
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
        //
        // #3072: MEASURED, and it holds. `WalCloneNeedsItsSidecarsTests` drives all four steps through the
        // readers' own `sqlite3_open_v2(SQLITE_OPEN_READONLY)` call: the clone comes out `wal`, it carries
        // no sidecars, it is refused read-only in that state, and after this line it reads with nothing
        // beside it. The sentence above is therefore evidence rather than reasoning.
        //
        // Worth knowing WHY it once looked refuted: the overnight review of 2026-08-20 tried the direct
        // version three times and it read fine. Asking a clone `PRAGMA journal_mode` opens it READ-WRITE,
        // which CREATES the `-shm` and `-wal`, so any probe that checks the mode before attempting the
        // read has already repaired the condition it is about to measure (L70). The first version of the
        // test above reproduced that result for exactly that reason.
        try run(selfContainedArguments(clone: clone),
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
