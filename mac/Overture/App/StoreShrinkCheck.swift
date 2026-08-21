import Foundation
import SQLite3

// #1409: the #663 guard catches a FOREIGN file at the store path. It cannot catch Overture's own store
// quietly losing most of its rows: a store with 3 shows is structurally identical to one with 501, so
// both open cleanly and look healthy. That is the failure mode with no detection at all, and the one
// that would cost the most before anyone noticed.
//
// The comparison needs no new bookkeeping. The launch backups already on disk ARE the history, so this
// counts the live store and the newest backup the same read-only way and compares them. That works on
// day one against backups taken long before it shipped, and the previous number can never drift from
// what was actually backed up, because it IS what was backed up.
//
// Read-only and read BEFORE anything opens the store, exactly like StoreSchemaGuard: this must never be
// the thing that touches a store that is already in trouble.
enum StoreShrinkCheck {
    // What the last backup can tell us. `.none` and `.unreadable` are deliberately different: the first
    // launch after this shipped has no history and that is not a finding, while a backup that exists and
    // cannot be counted must not pass as "fine". The case this feature exists for is the one where
    // something is already wrong, which is when a read is most likely to fail.
    enum Previous: Equatable {
        case none
        case count(Int)
        case unreadable(String)   // the folder name, so the warning can name what it could not read
        // #3036: the backups folder ITSELF could not be listed. Different from `.none` (there is no
        // history yet) and from `.unreadable` (one backup could not be counted), because the next move
        // differs: nothing here names a backup to check, only a folder Overture could not open at all.
        // No payload, unlike `.unreadable`: the folder's full path is already on screen under the
        // sentence, selectable, so naming it in the sentence would be the same fact twice (#843).
        case backupsUnreadable
    }

    // Below half, and at least this many rows gone. The absolute floor is what keeps a new store going
    // from 4 shows to 1 quiet: a check that cried wolf there would be ignored long before the day it
    // mattered.
    static let minimumDrop = 10

    // Title AND message, because the two cases mean different things and one heading cannot honestly
    // cover both: "some of your shows may be missing" would overclaim when the truth is only that the
    // comparison could not be made. The heading says what it MEANS; the message carries the evidence,
    // so neither is the other one restated (#843).
    struct Finding: Equatable {
        let title: String
        let message: String
    }

    static func warning(live: Int, previous: Previous) -> Finding? {
        switch previous {
        case .none:
            return nil
        case .unreadable(let folder):
            return Finding(title: unreadableTitle, message: unreadableBackupWarning(folder: folder))
        case .backupsUnreadable:
            return Finding(title: unreadableTitle, message: unreadableBackupsWarning)
        case .count(let previousCount):
            guard previousCount - live >= minimumDrop, live * 2 < previousCount else { return nil }
            return Finding(title: shrankTitle, message: shrankWarning(live: live, previous: previousCount))
        }
    }

    // The whole check, given the data directory: nil when there is nothing to say.
    static func check(dataDirectory: URL, fileManager: FileManager = .default) -> Finding? {
        let storeURL = dataDirectory.appendingPathComponent(StoreLocation.storeFilename)
        // No store yet is a fresh install, not a collapse. A store that exists but cannot be counted is
        // left to StoreSchemaGuard, which refuses the launch outright and says so far more precisely.
        guard let live = rowCount(at: storeURL) else { return nil }
        return warning(live: live, previous: previousCount(dataDirectory: dataDirectory, fileManager: fileManager))
    }

    // The newest REAL backup's count. #1410 named refusal snapshots `.foreign` because they hold another
    // app's file; counting one here would compare Dan's shows against iCloud Mail's rows.
    static func previousCount(dataDirectory: URL, fileManager: FileManager = .default) -> Previous {
        let backups = StoreBackup.backupsDirectory(dataDirectory: dataDirectory)
        // #3036: a listing that FAILED used to fall to an empty array and then to `.none`, so a folder
        // Overture could not open read as a first launch with no history. Absent really is no history;
        // present and unlistable is a refusal, and the launch where that happens is exactly the one this
        // check exists for (L105, L42).
        guard fileManager.fileExists(atPath: backups.path) else { return .none }
        guard let entries = try? fileManager.contentsOfDirectory(atPath: backups.path) else {
            return .backupsUnreadable
        }
        let folders = entries
            .filter { StoreBackup.isRotatableBackupFolder($0) }
            .sorted()
        guard let newest = folders.last else { return .none }
        let store = backups.appendingPathComponent(newest)
            .appendingPathComponent(StoreLocation.storeFilename)
        guard let count = rowCount(at: store) else { return .unreadable(newest) }
        return .count(count)
    }

    // nil, never 0, when the file cannot be read as Overture's store: zero rows would read as "the store
    // emptied", inventing a catastrophe out of a file that simply could not be counted.
    static func rowCount(at storeURL: URL) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        // copy-inventory:ignore-start  SQL, not a sentence Overture says to Dan
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ZPROSPECT;", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        // copy-inventory:ignore-end
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // The words. Dan reads these once, at launch, possibly while worried, so each says the two numbers,
    // that nothing has been changed, and the one move that helps.
    static let shrankTitle = "Some of your shows may be missing"
    static let unreadableTitle = "Overture cannot tell whether anything is missing"

    static func shrankWarning(live: Int, previous: Int) -> String {
        "Overture opened with \(live) \(live == 1 ? "show" : "shows"). Its most recent backup holds "
            + "\(previous). Nothing has been changed. If that drop is a surprise, quit Overture and "
            + "restore a backup before working: every launch takes another backup, and only the last "
            + "ten are kept."
    }

    static func unreadableBackupWarning(folder: String) -> String {
        "Its most recent backup (\(folder)) could not be read. Nothing has been changed. Check that "
            + "backup before working."
    }

    static let unreadableBackupsWarning =
        "Overture could not open its backup folder, so there is nothing to compare against. Nothing has "
            + "been changed. Check that folder before working."

    // Where they are, said once, for the sheet to show under the sentence above.
    static func backupsPath(dataDirectory: URL) -> String {
        StoreBackup.backupsDirectory(dataDirectory: dataDirectory).path
    }
}
