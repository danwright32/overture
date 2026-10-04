import Darwin
import Foundation
import SwiftData

// #4061: every file-backed `ModelContainer` a test opens, and the one way its directory is removed.
//
// THE DEFECT. A test removed a store's directory (by `removeItem`, a `defer`, or `TemporarySandboxes`
// going out of scope) while the container over it still held the SQLite files open. SQLite logs
// `BUG IN CLIENT OF libsqlite3.dylib: database integrity compromised by API violation: vnode unlinked
// while in use` for every file, and that is the mild outcome. On 2026-09-29 the Phase 0c rows probe
// left a context with UNSAVED changes over its 0c.5 store; a SwiftData run loop timer fired during
// 0c.6, faulted a row from the deleted file, threw `NSInternalInconsistencyException` and aborted
// xctest, so a run whose readings were complete reported TEST FAILED.
//
// WHY RELEASING THE REFERENCES IS NOT ENOUGH, measured rather than assumed (a standalone SwiftData
// program, 2026-09-29, on the macOS these tests run on). In that program a `ModelContext(container)`
// autosaved (inside xctest it does not, and a container's `mainContext` always does), and the container
// and context both stayed alive after every reference to them went out of
// scope and after two seconds of run loop, with the store's three files still open. Removing the
// directory then and running the loop for eight seconds reproduced the abort exactly. What closes the
// files is `deleteAllData()`: 0 files open straight after it, and eight seconds of run loop with the
// unsaved change still pending did not fault.
//
// So a test opens a file store through `container(for:configurations:)`, which records it, and removes
// the directory through `remove(_:)` (or a `TemporarySandboxes`, whose `deinit` calls `remove(_:)` itself).
// `FileStoresGuardTests` fails on a bare file-backed `ModelContainer(` anywhere in the test sources, so
// the next suite cannot quietly go back to it (L27, L613).
enum FileStores {

    private static let lock = NSLock()
    /// WEAK, so recording a container never keeps it alive: one nothing else references is released (and
    /// its files closed) exactly as it would have been without this, and `close(under:)` acts on the rest.
    private final class WeakContainer {
        weak var container: ModelContainer?
        init(_ container: ModelContainer) { self.container = container }
    }
    nonisolated(unsafe) private static var held: [WeakContainer] = []

    /// A file-backed container, recorded so `close(under:)` can release it before its files go.
    static func container(for schema: Schema, configurations: [ModelConfiguration]) throws -> ModelContainer {
        let made = try ModelContainer(for: schema, configurations: configurations)
        lock.withLock { held.append(WeakContainer(made)) }
        return made
    }

    /// Releases every recorded container with a store under `dir`, then reports the files under `dir`
    /// this process STILL holds open. An empty answer is the only one that makes removing `dir` safe.
    ///
    /// Refuses to release anything outside the per-user temp folder: `deleteAllData()` destroys the
    /// store it is pointed at, so it must never be able to reach Dan's live store, whatever a caller
    /// passes (L42). A path outside the temp folder is left open and reported as open.
    ///
    /// `mainQueueDeadline` bounds the one wait in here, for the main queue to drop a main context's changes
    /// when the close runs off the main thread (#4395, below). Past it nothing is destroyed: the stores stay
    /// open and are reported open, so `remove(_:)` leaves the directory in place rather than unlinking it.
    @discardableResult
    static func close(under dir: URL, mainQueueDeadline: TimeInterval = 10) -> [String] {
        guard let root = realPath(dir) else {
            // The directory is already gone, so there is nothing on disk to close or protect; its recorded
            // containers are only forgotten, by their configured path, so they are not held for the life of
            // the process.
            let gone = dir.standardizedFileURL.path
            lock.withLock {
                held.removeAll { box in
                    guard let c = box.container else { return true }
                    return c.configurations.contains { isInside($0.url.standardizedFileURL.path, gone) }
                }
            }
            return []
        }
        guard let scratch = realPath(URL(fileURLWithPath: NSTemporaryDirectory())), root != scratch, isInside(root, scratch) else {
            return openFiles(under: dir)
        }
        let closing: [ModelContainer] = lock.withLock {
            held.removeAll { $0.container == nil }
            let mine = held.compactMap(\.container).filter { container in
                container.configurations.contains { config in
                    guard let store = storeDirectory(config.url) else { return false }
                    return isInside(store, root)
                }
            }
            held.removeAll { box in mine.contains { $0 === box.container } }
            return mine
        }
        // The main context autosaves by default, and one left holding unsaved changes over a destroyed
        // store logs "No DataStores were found on the ModelContainer but ModelContext has changes" on every
        // autosave tick for the rest of the process (measured 2026-09-29: 634 lines in seven minutes of a
        // full suite run). Its changes are dropped first where that is legal, on the main thread; a context a
        // test made itself is out of reach here and, built with `ModelContext(container)` inside a test
        // process, does not autosave (measured the same day).
        // Off the main thread (a sandbox released by an async test, or a suite instance released on a worker)
        // the same step is sent to the main queue rather than skipped, and this WAITS for it before anything is
        // destroyed (#4395). It used to be posted and left, on the reading that landing just after
        // `deleteAllData()` was safe, and that reading was about an unsaved change, not about the hop itself:
        // the hop could run on the main thread WHILE `deleteAllData()` ran here, reach the main context mid
        // teardown, and hit SwiftData's own trap, "Container does not have any data stores"
        // (ModelContext.swift:324). That killed the CI test worker in 6 of the last 100 failed runs (all in
        // `DebugStagingTests`, whose file-backed test is not on the main actor), and once in 200 local
        // repetitions of that suite on 2026-10-04, crash report xctest-2026-10-04-144533.ips, whose trapping
        // frame is `dropMainContextChanges` called from this hop. A deadline rather than an unbounded wait,
        // so a main thread that is itself blocked cannot hang the test process (L110); past it, nothing is
        // destroyed and the files are reported still open.
        if Thread.isMainThread {
            MainActor.assumeIsolated { for container in closing { dropMainContextChanges(container) } }
        } else if !closing.isEmpty {
            let dropped = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { for container in closing { dropMainContextChanges(container) } }
                dropped.signal()
            }
            guard dropped.wait(timeout: .now() + mainQueueDeadline) == .success else {
                print("FileStores: the main queue did not drop \(closing.count) container(s)' main context "
                      + "changes within \(mainQueueDeadline)s, so their stores under \(dir.lastPathComponent) "
                      + "were left open rather than destroyed under a hop still waiting to run (#4395)")
                // Back in the registry, so the next close of this directory, or of a parent, still finds them.
                lock.withLock { held.append(contentsOf: closing.map(WeakContainer.init)) }
                return openFiles(under: dir)
            }
        }
        if #available(macOS 15, *) {
            for container in closing { container.deleteAllData() }
        }
        return openFiles(under: dir)
    }

    @MainActor
    private static func dropMainContextChanges(_ container: ModelContainer) {
        container.mainContext.autosaveEnabled = false
        container.mainContext.rollback()
    }

    /// Whether `container` is still recorded, for the tests that pin the registry's behaviour.
    static func isRecorded(_ container: ModelContainer) -> Bool {
        lock.withLock { held.contains { $0.container === container } }
    }

    /// Closes the stores under `dir` and removes it. When a file under it is still open (a container
    /// something else opened, or a raw descriptor), the directory is LEFT IN PLACE and said so on the
    /// output: unlinking an open SQLite file is the API violation itself, and a directory left behind is
    /// something `scripts/check-temp-dir-leaks.sh` can see, where a corrupt read is not (L10).
    @discardableResult
    static func remove(_ dir: URL, fileManager: FileManager = .default) -> Bool {
        let stillOpen = close(under: dir)
        guard stillOpen.isEmpty else {
            print("FileStores: left \(dir.lastPathComponent) in place, \(stillOpen.count) file(s) under it "
                  + "still open in this process (#4061): "
                  + stillOpen.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
            return false
        }
        try? fileManager.removeItem(at: dir)
        return true
    }

    /// Every file under `dir` that one of this process's descriptors refers to, by the kernel's own
    /// account of each descriptor (`F_GETPATH`), so a store opened by ANY route is seen, not only one
    /// recorded here.
    static func openFiles(under dir: URL) -> [String] {
        guard let root = realPath(dir) else { return [] }
        let pid = getpid()
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [] }
        var out: [String] = []
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for info in fds.prefix(Int(got) / stride) where info.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            guard fcntl(info.proc_fd, F_GETPATH, &buffer) != -1 else { continue }
            let path = String(cString: buffer)
            if isInside(path, root) { out.append(path) }
        }
        return out
    }

    // MARK: - Paths

    /// The canonical path, `/private/var/...` rather than `/var/...`, which is how the kernel names an
    /// open file. `URL.resolvingSymlinksInPath` strips `/private` instead, so it cannot be compared with
    /// `F_GETPATH`'s answer. Nil when the path does not exist.
    static func realPath(_ url: URL) -> String? {
        guard let resolved = Darwin.realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The directory holding a store file, canonical. The store file itself may already be gone.
    private static func storeDirectory(_ url: URL) -> String? {
        realPath(url.deletingLastPathComponent())
    }

    private static func isInside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
