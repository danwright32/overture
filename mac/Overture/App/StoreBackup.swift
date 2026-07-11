import Foundation

// #601: a rotating, launch-time backup of the local SwiftData store, so an app bug or accidental
// wipe doesn't cost every prospect/contact/outreach record. Only a handful of one-off manual
// copies existed before this (made by hand ahead of risky migrations); this makes it automatic.
enum StoreBackup {
    // Where backups live: a dedicated subfolder of the same data directory the live store is in,
    // so Debug and Release backups stay isolated exactly like everything else under StoreLocation.
    static func backupsDirectory(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("overture-store-backups", isDirectory: true)
    }

    // The store filename plus its WAL-mode sidecars; not every one is always present (e.g. a
    // cleanly-checkpointed store has no -shm), so each is copied only when it actually exists.
    private static let storeFilenames = ["default.store", "default.store-wal", "default.store-shm"]

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    // Copies the live store (+ its -wal/-shm sidecars, when present) into a new dated subfolder.
    // Returns nil when there's nothing to back up yet (a fresh install with no store).
    @discardableResult
    static func makeBackup(dataDirectory: URL, now: Date, fileManager: FileManager = .default) -> URL? {
        let storeURL = dataDirectory.appendingPathComponent("default.store")
        guard fileManager.fileExists(atPath: storeURL.path) else { return nil }

        let destination = backupsDirectory(dataDirectory: dataDirectory)
            .appendingPathComponent(timestampFormatter.string(from: now), isDirectory: true)
        // A second launch in the same second (the app's own crash-relaunch-loop concern, per
        // #601's red-team) would otherwise collide on this exact folder name; treat an existing
        // one as already backed up rather than attempting (and failing) another copy into it.
        guard !fileManager.fileExists(atPath: destination.path) else { return destination }
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        for filename in storeFilenames {
            let source = dataDirectory.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.copyItem(at: source, to: destination.appendingPathComponent(filename))
        }
        appendLog("\(timestampFormatter.string(from: now)) success",
                  backupsDirectory: backupsDirectory(dataDirectory: dataDirectory), fileManager: fileManager)
        return destination
    }

    // #608: one line per launch, forever, with nothing trimming it. Negligible per launch (a few
    // dozen bytes), which is exactly why it would have grown for years before anyone looked. 256 KB
    // still holds several thousand launches of history, far more than is ever useful, while keeping
    // the file trivially small. Deliberately much tighter than the agent's 5 MB stdout/stderr cap:
    // that log carries real diagnostic output, this one carries one dated line.
    static let maxLogBytes = 256 * 1_024

    // A small, self-contained log colocated with the backups themselves: there's no existing
    // app-wide event log to hook into, and this is more discoverable than a buried one would be
    // anyway, sitting right next to the thing it's recording the history of.
    private static func appendLog(_ line: String, backupsDirectory: URL, fileManager: FileManager) {
        let logURL = backupsDirectory.appendingPathComponent("backup.log")
        // Cap BEFORE appending, through the same copytruncate helper the agent's logs use (#608), so
        // the file can never sit above the cap between launches. A missing log (the first launch) is
        // a silent no-op.
        LogRotation.cap(files: [logURL], maxBytes: maxLogBytes, fileManager: fileManager)

        let entry = line + "\n"
        guard let data = entry.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    // Deletes all but the `keep` most recent dated backup folders. Folder names are
    // `yyyyMMdd-HHmmss`, which sort chronologically as plain strings, so no date parsing needed.
    static func pruneOldBackups(in backupsDirectory: URL, keep: Int, fileManager: FileManager = .default) {
        let entries = (try? fileManager.contentsOfDirectory(
            at: backupsDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let dated = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard dated.count > keep else { return }
        for old in dated.dropLast(keep) {
            try? fileManager.removeItem(at: old)
        }
    }

    // The launch-time policy, generic over whatever "open the store" returns so it's testable
    // without a real ModelContainer. Always backs up first (the window before `open()` runs is
    // the safe one: nothing has the store open yet). Only prunes old backups when `open`
    // succeeds: an undetected corrupted store must never cause its own last-good backups to be
    // rotated away just because this launch's open attempt failed (#602 red-team finding).
    static func performLaunchBackup<Container>(
        dataDirectory: URL, now: Date, keep: Int, fileManager: FileManager = .default,
        open: () -> Container?
    ) -> Container? {
        makeBackup(dataDirectory: dataDirectory, now: now, fileManager: fileManager)
        let result = open()
        if result != nil {
            pruneOldBackups(in: backupsDirectory(dataDirectory: dataDirectory), keep: keep, fileManager: fileManager)
        }
        return result
    }
}
