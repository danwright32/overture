import Foundation

// The one-time move of the live store off the shared Application Support root (and off SwiftData's
// default `default.store` filename) and onto a path only Overture uses. See StoreLocation for why.
//
// This runs at launch BEFORE the store is opened and before the single-writer lock is taken, because
// the lock itself lives at the new path. It is deliberately conservative: it moves a file only when
// that file is genuinely Overture's, it never overwrites a store already sitting at the new path, and
// when it cannot finish it says so instead of letting the app come up on a brand new empty store,
// which would read to Dan as every prospect being gone.
enum StoreRelocation {
    enum Outcome: Equatable {
        // Nothing to do: already on the new path, or a fresh install with no store anywhere.
        case notNeeded
        // The store (and its WAL sidecars) moved.
        case migrated
        // Refused, with a reason to show on the store-unavailable screen. Nothing was changed.
        case blocked(reason: String)
    }

    // The store plus its WAL-mode sidecars. Ordered so the sidecars are in place at the destination
    // BEFORE the store file itself is: the store's existence at the new path is what every later
    // launch treats as "already migrated", so it must never be the first thing to appear. A crash
    // halfway through then leaves the old location authoritative and the next launch retries.
    private static let sidecarSuffixes = ["-wal", "-shm"]

    static func migrate(
        legacyStoreURL: URL,
        newStoreURL: URL,
        isOvertureStore: (URL) -> Bool = { StoreSchemaGuard.hasExpectedSchema(at: $0) },
        fileManager: FileManager = .default
    ) -> Outcome {
        // Already moved. Whatever sits at the old path now belongs to whichever app put it there.
        guard !fileManager.fileExists(atPath: newStoreURL.path) else { return .notNeeded }
        guard fileManager.fileExists(atPath: legacyStoreURL.path) else { return .notNeeded }

        // The #663 check, applied before moving rather than before opening. Carrying a foreign file
        // onto Overture's new path would defeat that guard by making the bad file look like ours.
        guard isOvertureStore(legacyStoreURL) else {
            // Deliberately the SAME sentence the #663 guard shows, not a second phrasing of it: from
            // Dan's side this is the identical situation (the file at that path isn't Overture's),
            // and the folder move is an implementation detail he has no reason to hear about.
            return .blocked(reason: StoreSchemaGuard.foreignFileReason(path: legacyStoreURL.path))
        }

        do {
            try fileManager.createDirectory(at: newStoreURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            for suffix in sidecarSuffixes {
                try copy(at: sibling(of: legacyStoreURL, suffix: suffix),
                         to: sibling(of: newStoreURL, suffix: suffix), fileManager: fileManager)
            }
            try copy(at: legacyStoreURL, to: newStoreURL, fileManager: fileManager)
        } catch {
            return .blocked(reason:
                "Overture couldn't move its data to \(newStoreURL.path): "
                + "\(error.localizedDescription). Your data is safe and unchanged at "
                + "\(legacyStoreURL.path).")
        }

        // The copies are in place, so the originals are now redundant. A failure here costs nothing:
        // the next launch sees the store already at the new path and does nothing.
        for url in [legacyStoreURL] + sidecarSuffixes.map({ sibling(of: legacyStoreURL, suffix: $0) }) {
            try? fileManager.removeItem(at: url)
        }
        return .migrated
    }

    private static func sibling(of storeURL: URL, suffix: String) -> URL {
        URL(fileURLWithPath: storeURL.path + suffix)
    }

    // Copy rather than move, so a crash mid-way can never leave the store at neither path. A stray
    // sidecar already at the destination (without its store, which we checked for above) is a
    // meaningless orphan and is replaced.
    private static func copy(at source: URL, to destination: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }
}
