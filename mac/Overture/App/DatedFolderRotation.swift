import Foundation

// #1878: the dated-folder rotation the store backup has used since #601, in one place, because a second
// thing now needs it (the paid run archive) and two copies of a retention rule is exactly how one of them
// quietly stops matching the other.
//
// It is three decisions, and all three were worked out the hard way in StoreBackup:
//
//   1. The folder name is `yyyyMMdd-HHmmss`, which sorts chronologically as a plain string, so keeping the
//      newest N needs no date parsing at all.
//   2. ONLY that exact shape is counted and deleted. A folder outside it (the #1410 refusal snapshot, a
//      copy someone kept by hand, a working folder left by a crash) is invisible to rotation, so a run of
//      odd cases can never age out the real history. This is the detail worth carrying over: without it,
//      a burst of refusals silently deleted every genuine backup.
//   3. Rotation deletes only what it is asked to, and answers every unknown in the keep direction.
enum DatedFolderRotation {
    static let stampFormat = "yyyyMMdd-HHmmss"

    // The zone is the CALLER's, because the two callers are stamping different kinds of instant and only
    // they know which. This is a filesystem timestamp either way, never a business date (L39 is about the
    // dates Overture reasons with, and nothing reasons with these).
    //
    //   The store backup stamps a local clock event, "when this Mac took the copy", and keeps the local
    //   default it has had since #601.
    //
    //   The paid run archive stamps the instant the RUN recorded for itself, which is already UTC in the
    //   file (`generatedAt` ends in Z), so it asks for UTC. That makes the folder name and the
    //   `generatedAt` inside it the same moment written the same way, instead of two renderings that
    //   differ by the reader's offset and look like different runs.
    static func stamp(_ date: Date, in timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = stampFormat
        f.timeZone = timeZone
        // A fixed format needs a fixed locale, or a non-Gregorian calendar on the reading Mac renders a
        // year that is not the one anything else here means.
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    // A plain `yyyyMMdd-HHmmss` folder, and the only thing rotation ever touches.
    static func isRotatableFolder(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 8, parts[1].count == 6 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    // Deletes all but the `keep` most recent dated folders. A directory that cannot be listed yields
    // nothing, so a rotation that cannot see the folders deletes none of them rather than guessing.
    static func prune(in directory: URL, keep: Int, fileManager: FileManager = .default) {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let dated = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .filter { isRotatableFolder($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard dated.count > keep else { return }
        for old in dated.dropLast(keep) {
            try? fileManager.removeItem(at: old)
        }
    }
}
