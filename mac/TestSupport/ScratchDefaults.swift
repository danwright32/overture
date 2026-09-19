import Foundation

// #3774: the ONE way a test obtains a `UserDefaults`, and it cleans up after itself.
//
// WHY IT EXISTS. Every `UserDefaults(suiteName:)` is a real file in `~/Library/Preferences`, and the tests
// built one per test with a UUID in its name and never deleted it. Measured 2026-09-10: that folder held
// 745,089 files, of which 528 were real preferences, and listing it took minutes, which slows every app on
// the Mac that reads its own preferences. They were deleted by hand that day and were back to 67,696 by
// 2026-09-19. A test that writes into the live Preferences folder is a test touching live user data (L2).
//
// WHY `removePersistentDomain` WAS NOT ENOUGH, measured 2026-09-19 on this Mac rather than assumed: it
// empties the domain and LEAVES THE FILE, so the ten call sites that "cleaned up" leaked exactly like the
// ones that did not. Deleting the file first is no better, because removing the domain afterwards writes
// it back. What works is the order below: remove the domain, synchronize, then delete the file.
//
// WHEN. At process exit, through `atexit`, because Swift Testing offers no suite teardown and a `UserDefaults`
// has no deinit to hang one on; a rule each call site had to opt into is what left 107 of 117 leaking (L621).
// Parallel testing runs several worker PROCESSES, and each one cleans up what it made.
//
// AND AFTER A CRASH, which runs no exit handler. The name carries the process id, so the first suite any
// later test process makes sweeps every file of ours whose owner is no longer running. Only files carrying
// this prefix and a dead owner's pid are touched, never anything matched by shape alone (L444): other apps'
// tests on this Mac name their suites however they like.
enum ScratchDefaults {

    // Says what the file is to anybody listing the folder, and is what the sweep and the runner match on.
    static let prefix = "overture-test-scratch."

    // Every suite this process made, so exit removes exactly those. Behind a lock: parallel tests in one
    // worker call `make` concurrently.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var made: [String] = []
    nonisolated(unsafe) private static var armed = false

    /// A fresh, private defaults suite. `label` only makes the file recognisable; uniqueness comes from the
    /// UUID, so two tests passing one label never share a suite.
    static func make(_ label: String = "suite") -> UserDefaults {
        makeNamed(label).defaults
    }

    /// The same, with the suite's name, for the tests that check its file.
    static func makeNamed(_ label: String) -> (defaults: UserDefaults, name: String) {
        let name = suiteName(label: label, pid: getpid(), id: UUID())
        lock.lock()
        let firstInThisProcess = !armed
        if firstInThisProcess {
            armed = true
            atexit { ScratchDefaults.removeEverythingMade() }
        }
        made.append(name)
        lock.unlock()
        if firstInThisProcess { sweepDeadOwners() }
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("UserDefaults refused the suite name \(name)")
        }
        return (defaults, name)
    }

    // PURE, so the naming and the owner reading can be tested without making a file.
    static func suiteName(label: String, pid: Int32, id: UUID) -> String {
        let safe = label.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        return "\(prefix)\(pid).\(String(safe))-\(id.uuidString)"
    }

    /// The pid that made a scratch file, from its name, or nil when the name is not one of ours.
    static func owner(ofFileNamed file: String) -> Int32? {
        guard file.hasPrefix(prefix), file.hasSuffix(".plist") else { return nil }
        let rest = file.dropFirst(prefix.count)
        guard let dot = rest.firstIndex(of: ".") else { return nil }
        return Int32(rest[rest.startIndex..<dot])
    }

    static var preferencesDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences")
    }

    /// Removes one suite THIS process made, in the only order measured to leave no file behind.
    static func remove(suiteNamed name: String) {
        let defaults = UserDefaults(suiteName: name)
        defaults?.removePersistentDomain(forName: name)
        defaults?.synchronize()
        try? FileManager.default.removeItem(at: preferencesDirectory.appendingPathComponent("\(name).plist"))
    }

    private static func removeEverythingMade() {
        lock.lock()
        let names = made
        made = []
        lock.unlock()
        for name in names { remove(suiteNamed: name) }
    }

    /// Deletes every scratch file whose owner is no longer running. Returns the names it removed.
    @discardableResult
    static func sweepDeadOwners(in directory: URL = preferencesDirectory,
                                isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed: [String] = []
        for file in files {
            guard let pid = owner(ofFileNamed: file), !isAlive(pid) else { continue }
            // The FILE only, never the domain: its owner is gone, so nothing holds changes to write back,
            // and asking the preferences daemon to remove a domain it is not holding WRITES an empty file
            // for it, which is the leak this exists to remove (measured with the probe above).
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            removed.append(String(file.dropLast(".plist".count)))
        }
        return removed
    }
}
