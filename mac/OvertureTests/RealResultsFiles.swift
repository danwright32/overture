import Foundation

// #2895: every real results file this Mac holds, in ONE place.
//
// Extracted from `NoRouteFoundAdoptionMeasurementTests` (#2925) unchanged when a second measurement
// needed the same walk. Two copies of "where the runs are" is how a later measurement comes to read a
// different set of files from the one beside it and neither reports a problem (L26, L107).
//
// The live pair plus every archived run of both slots. A results file is OVERWRITTEN by the next run of
// its slot, so the archives are most of the history and the live pair is only the newest two.
enum RealResultsFiles {
    static var handoffDirectory: URL {
        StoreLocation.dataDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    static func urls() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        var directories = [handoffDirectory]
        for archives in ["prep-run-archives", "check-run-archives"] {
            let root = handoffDirectory.appendingPathComponent(archives)
            let runs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            directories.append(contentsOf: runs.filter { $0.hasDirectoryPath })
        }
        for directory in directories {
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            out.append(contentsOf: files.filter {
                $0.lastPathComponent == "overture-prep-results.json"
                    || $0.lastPathComponent == "overture-check-results.json"
            })
        }
        return out
    }

    /// When the file was written, or `distantPast` when the filesystem will not say. Old enough to be
    /// excluded from any "since this shipped" count, which is the direction that cannot manufacture a
    /// false accusation out of a file whose date could not be read (L42).
    static func writtenAt(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date.distantPast
    }
}
