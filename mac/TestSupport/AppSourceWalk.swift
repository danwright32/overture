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
    static func urls(under root: URL, floor: Int = appFloor, extensions: Set<String> = ["swift"]) -> [URL] {
        let found = memo.urls(root: root, extensions: extensions) { walk(root, extensions: extensions) }
        // Evaluated on EVERY call, never once when the memo was filled. Two guards standing on the
        // same broken path must both go red: a refusal that reached only whichever of them happened
        // to walk first would let the other report a clean app (#3235, L98).
        if let refusal = refusal(found: found.count, floor: floor, directory: root.path) {
            Issue.record(Comment(rawValue: refusal))
        }
        return found
    }

    // The same walk with each file's text already read, for the guards that scan contents. A file
    // that cannot be read is dropped from the list and counted against the floor, so a directory of
    // unreadable files refuses exactly like an empty one.
    static func files(under root: URL, floor: Int = appFloor, extensions: Set<String> = ["swift"]) -> [File] {
        let found = memo.files(root: root, extensions: extensions) {
            walk(root, extensions: extensions).compactMap { url -> File? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return File(url: url, name: url.lastPathComponent, text: text)
            }
        }
        if let refusal = refusal(found: found.count, floor: floor, directory: root.path) {
            Issue.record(Comment(rawValue: refusal))
        }
        return found
    }

    // The app itself, which is what almost every caller wants.
    static func appURLs(floor: Int = appFloor) -> [URL] { urls(under: RepoRoot.app, floor: floor) }
    static func appFiles(floor: Int = appFloor) -> [File] { files(under: RepoRoot.app, floor: floor) }

    // #2839: the extensions are a parameter rather than a hard-coded "swift", because a guard over TEST
    // DATA has to read the fixtures too (.json, .txt, .md, .html) and the alternative was that guard
    // declaring its own enumerator, which is exactly what noTestFileDeclaresItsOwnAppSourceWalker forbids
    // and what #2311 consolidated. Defaulted to swift, so every existing caller is unchanged.
    // #3235: one walk per (root, extensions) per process, because the same scan was being paid for
    // twelve times a run. What it will NOT keep is the whole safety of it: an EMPTY result is never
    // remembered, so a broken path re-walks and re-refuses instead of being handed to every guard in
    // the suite as "checked everything, found nothing wrong" (L286). The floor is deliberately NOT part
    // of the key and NOT consulted here: the refusal is the caller's, evaluated per call, so a result
    // kept for a caller with a low floor cannot pass silently to one with a high floor (L98).
    //
    // A class behind a lock rather than a bare `static var`, so this is still correct when the suite
    // runs its tests in parallel.
    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var urlsByKey: [String: [URL]] = [:]
        private var filesByKey: [String: [File]] = [:]
        private var walks = 0

        var walksPerformed: Int {
            lock.lock(); defer { lock.unlock() }
            return walks
        }

        private func key(_ root: URL, _ extensions: Set<String>) -> String {
            "\(root.standardizedFileURL.path)\u{1F}\(extensions.sorted().joined(separator: ","))"
        }

        func urls(root: URL, extensions: Set<String>, build: () -> [URL]) -> [URL] {
            let k = key(root, extensions)
            lock.lock()
            if let hit = urlsByKey[k] { lock.unlock(); return hit }
            walks += 1
            lock.unlock()
            let found = build()
            guard !found.isEmpty else { return found }
            lock.lock(); urlsByKey[k] = found; lock.unlock()
            return found
        }

        func files(root: URL, extensions: Set<String>, build: () -> [File]) -> [File] {
            let k = key(root, extensions)
            lock.lock()
            if let hit = filesByKey[k] { lock.unlock(); return hit }
            walks += 1
            lock.unlock()
            let found = build()
            guard !found.isEmpty else { return found }
            lock.lock(); filesByKey[k] = found; lock.unlock()
            return found
        }
    }

    private static let memo = Memo()

    // How many times a walk has actually touched the disk. Exists so the memo can be PROVED rather
    // than assumed: a memo that silently stopped working would be invisible otherwise, because the
    // fallback is correct and merely slower (L289).
    static var walksPerformed: Int { memo.walksPerformed }

    private static func walk(_ root: URL, extensions: Set<String> = ["swift"]) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { extensions.contains($0.pathExtension) }
            .sorted { $0.path < $1.path }
    }
}
