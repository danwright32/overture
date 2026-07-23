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
    // Derived from StoreLocation rather than spelled out, so the store's name lives in one place:
    // backups taken before the #663-follow-up rename hold `default.store` instead, and restoring one
    // of those means renaming it on the way in (see AGENTS.md).
    private static var storeFilenames: [String] {
        [StoreLocation.storeFilename, StoreLocation.storeFilename + "-wal", StoreLocation.storeFilename + "-shm"]
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    // #1410: WHY a snapshot is being taken, because it changes what the snapshot is worth. The launch
    // backup is a copy of Dan's data. The one the #663 guard takes before refusing to open is a copy of
    // a file that was NOT Dan's data, kept only as evidence of whatever landed at that path. Logging
    // and naming them identically (which is what happened on 2026-07-23) makes the second one read as
    // the most recent good backup.
    enum Reason: Equatable {
        case launch
        case foreignFile

        // Appended to the folder name so the distinction survives in the folder listing, not just in
        // the log. Kept out of the plain `yyyyMMdd-HHmmss` shape on purpose: pruneOldBackups counts and
        // deletes only that shape, so a refusal can never age out a real backup.
        var folderSuffix: String { self == .foreignFile ? ".foreign" : "" }
    }

    // The log's own words. Constants so a test names the same thing the code writes, rather than
    // re-typing a sentence that can drift.
    // copy-inventory:ignore-start  backup.log is a diagnostic record, not the app's voice on screen
    static let foreignFileLogNote =
        "refused: the file at the store path was not Overture's own database, so nothing was opened. "
        + "This folder holds a copy of that file, not a backup of your data."
    static let nothingCopiedLogNote = "failed: nothing was copied, so there is no backup for this launch."
    static func incompleteLogNote(copied: Int, of expected: Int) -> String {
        "incomplete: copied \(copied) of \(expected) files, so this backup may not restore cleanly."
    }
    // copy-inventory:ignore-end

    // Copies the live store (+ its -wal/-shm sidecars, when present) into a new dated subfolder.
    // Returns nil when there's nothing to back up yet (a fresh install with no store), and #1410 also
    // when the copy failed outright: handing back a folder path implies a backup is sitting in it.
    @discardableResult
    static func makeBackup(dataDirectory: URL, now: Date, reason: Reason = .launch,
                           fileManager: FileManager = .default) -> URL? {
        let storeURL = dataDirectory.appendingPathComponent(StoreLocation.storeFilename)
        guard fileManager.fileExists(atPath: storeURL.path) else { return nil }

        let stamp = timestampFormatter.string(from: now)
        let backups = backupsDirectory(dataDirectory: dataDirectory)
        let destination = backups.appendingPathComponent(stamp + reason.folderSuffix, isDirectory: true)
        // A second launch in the same second (the app's own crash-relaunch-loop concern, per
        // #601's red-team) would otherwise collide on this exact folder name; treat an existing
        // one as already backed up rather than attempting (and failing) another copy into it.
        guard !fileManager.fileExists(atPath: destination.path) else { return destination }
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let present = storeFilenames.filter {
            fileManager.fileExists(atPath: dataDirectory.appendingPathComponent($0).path)
        }
        var copied = 0
        for filename in present {
            let source = dataDirectory.appendingPathComponent(filename)
            // #1410: a failed copy used to be swallowed here and then logged as a success, so a backup
            // that copied nothing at all was indistinguishable from a good one.
            do {
                try fileManager.copyItem(at: source, to: destination.appendingPathComponent(filename))
                copied += 1
            } catch {
                continue
            }
        }

        guard copied > 0 else {
            appendLog("\(stamp) \(nothingCopiedLogNote)", backupsDirectory: backups, fileManager: fileManager)
            // Leaving the empty folder would put a directory holding nothing into the rotation, where it
            // would be counted as one of the ten kept and could push a real backup off the end.
            try? fileManager.removeItem(at: destination)
            return nil
        }

        let outcome: String
        switch (reason, copied == present.count) {
        case (.foreignFile, _): outcome = foreignFileLogNote
        case (.launch, true): outcome = "success"
        case (.launch, false): outcome = incompleteLogNote(copied: copied, of: present.count)
        }
        appendLog("\(stamp) \(outcome)", backupsDirectory: backups, fileManager: fileManager)
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

    // A plain `yyyyMMdd-HHmmss` folder: a real backup, and the only thing rotation touches. #1410: a
    // refusal snapshot (`yyyyMMdd-HHmmss.foreign`) deliberately fails this, so it is neither counted
    // toward `keep` nor deleted. It is evidence of a file that should never have been at that path,
    // and a burst of them must not quietly rotate away every real backup Dan has.
    static func isRotatableBackupFolder(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 8, parts[1].count == 6 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    // Deletes all but the `keep` most recent dated backup folders. Folder names are
    // `yyyyMMdd-HHmmss`, which sort chronologically as plain strings, so no date parsing needed.
    static func pruneOldBackups(in backupsDirectory: URL, keep: Int, fileManager: FileManager = .default) {
        let entries = (try? fileManager.contentsOfDirectory(
            at: backupsDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let dated = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .filter { isRotatableBackupFolder($0.lastPathComponent) }
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
        dataDirectory: URL, now: Date, keep: Int, reason: Reason = .launch,
        fileManager: FileManager = .default,
        open: () -> Container?
    ) -> Container? {
        makeBackup(dataDirectory: dataDirectory, now: now, reason: reason, fileManager: fileManager)
        let result = open()
        if result != nil {
            pruneOldBackups(in: backupsDirectory(dataDirectory: dataDirectory), keep: keep, fileManager: fileManager)
        }
        return result
    }
}
