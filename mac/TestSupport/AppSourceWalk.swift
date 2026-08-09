import Foundation
import Testing

// #2311: one walk over the app's Swift sources, which REFUSES when it comes back empty.
//
// Several source guards walk a directory of app Swift and assert nothing in it matches a forbidden
// shape. Every one of them passes vacuously when the directory resolves to the wrong place: the walk
// yields no files, no file matches, and the guard reports a clean app. #1993 found three doing
// exactly this, and #1967 is the same failure having already happened for real, where eleven tests
// reported the app contained no user-facing copy when the truth was a broken path.
//
// #1993 fixed the PATHS, not the SHAPE. A guard standing on its own private walker still cannot tell
// "I checked everything and found no problem" from "I checked nothing", and those are the two most
// different outcomes a guard has. So the refusal lives in the WALK rather than in each guard's own
// floor: a new guard written next year inherits it without knowing it exists, which is the only
// version of this that survives the next reorganisation.
//
// The floor is a "this path still resolves" assertion, not a pin on how big the app is. It is set far
// below the real count deliberately: a tight number fails on ordinary deletions and teaches the next
// person to lower it without reading, which is how a guard goes quietly vacuous (L63).
enum AppSourceWalk {

    // Measured 2026-08-09: 300+ Swift files under mac/Overture. Anything under this many means the
    // path is wrong, not that the app shrank.
    static let appFloor = 100

    struct File {
        let url: URL
        let name: String      // the file's own name, which is how most guards report a finding
        let text: String
    }

    // The decision, as a pure function, so the refusal itself can be exercised rather than only ever
    // being watched not to happen.
    static func refusal(found: Int, floor: Int, directory: String) -> String? {
        guard found < floor else { return nil }
        return """
            This guard walked \(directory) and found \(found) Swift files, fewer than the \(floor) it \
            needs to be checking anything at all. That is a broken path, not a clean app: with nothing \
            to walk, every assertion below it passes over every file it exists to check (#2311, #1967).
            """
    }

    // Every Swift file under `root`, refusing out loud when the walk comes back short.
    //
    // The refusal is recorded as a test issue from in here, so a guard that forgets to assert its own
    // floor still cannot pass on an empty walk. It returns what it found rather than halting, so one
    // broken path reports itself once instead of taking down the whole run.
    static func urls(under root: URL, floor: Int = appFloor) -> [URL] {
        let found = walk(root)
        if let refusal = refusal(found: found.count, floor: floor, directory: root.path) {
            Issue.record(Comment(rawValue: refusal))
        }
        return found
    }

    // The same walk with each file's text already read, for the guards that scan contents. A file
    // that cannot be read is dropped from the list and counted against the floor, so a directory of
    // unreadable files refuses exactly like an empty one.
    static func files(under root: URL, floor: Int = appFloor) -> [File] {
        let found = walk(root).compactMap { url -> File? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return File(url: url, name: url.lastPathComponent, text: text)
        }
        if let refusal = refusal(found: found.count, floor: floor, directory: root.path) {
            Issue.record(Comment(rawValue: refusal))
        }
        return found
    }

    // The app itself, which is what almost every caller wants.
    static func appURLs(floor: Int = appFloor) -> [URL] { urls(under: RepoRoot.app, floor: floor) }
    static func appFiles(floor: Int = appFloor) -> [File] { files(under: RepoRoot.app, floor: floor) }

    private static func walk(_ root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }
}
