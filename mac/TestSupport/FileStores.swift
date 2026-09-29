import Darwin
import Foundation
import SwiftData

// #4061: every file-backed `ModelContainer` a test opens, and the one way its directory is removed.
//
// THE DEFECT. A test removed a store's directory (by `removeItem`, a `defer`, or `TemporarySandboxes`
// going out of scope) while the container over it still held the SQLite files open. SQLite logs
// `BUG IN CLIENT OF libsqlite3.dylib: database integrity compromised by API violation: vnode unlinked
// while in use` for every file, and that is the mild outcome. On 2026-09-29 the Phase 0c rows probe
// left a context with UNSAVED changes over its 0c.5 store; SwiftData's autosave timer fired during
// 0c.6, faulted a row from the deleted file, threw `NSInternalInconsistencyException` and aborted
// xctest, so a run whose readings were complete reported TEST FAILED.
//
// WHY RELEASING THE REFERENCES IS NOT ENOUGH, measured rather than assumed (a standalone SwiftData
// program, 2026-09-29, on the macOS these tests run on). A `ModelContext(container)` AUTOSAVES by
// default, and the container and context both stayed alive after every reference to them went out of
// scope and after two seconds of run loop, with the store's three files still open. Removing the
// directory then and running the loop for eight seconds reproduced the abort exactly. What closes the
// files is `deleteAllData()`: 0 files open straight after it, and eight seconds of run loop with the
// unsaved change still pending did not fault.
//
// So a test opens a file store through `container(for:configurations:)`, which records it, and removes
// the directory through `remove(_:)` (or a `TemporarySandboxes`, which calls `close(under:)` itself).
// `FileStoresGuardTests` fails on a bare file-backed `ModelContainer(` anywhere in the test sources, so
// the next suite cannot quietly go back to it (L27, L613).
enum FileStores {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: [ModelContainer] = []

    /// A file-backed container, recorded so `close(under:)` can release it before its files go.
    static func container(for schema: Schema, configurations: [ModelConfiguration]) throws -> ModelContainer {
        let made = try ModelContainer(for: schema, configurations: configurations)
        lock.withLock { held.append(made) }
        return made
    }

    /// Releases every recorded container with a store under `dir`, then reports the files under `dir`
    /// this process STILL holds open. An empty answer is the only one that makes removing `dir` safe.
    ///
    /// Refuses to release anything outside the per-user temp folder: `deleteAllData()` destroys the
    /// store it is pointed at, so it must never be able to reach Dan's live store, whatever a caller
    /// passes (L42). A path outside the temp folder is left open and reported as open.
    @discardableResult
    static func close(under dir: URL) -> [String] {
        guard let root = realPath(dir) else { return [] }
        guard let scratch = realPath(URL(fileURLWithPath: NSTemporaryDirectory())), isInside(root, scratch) else {
            return openFiles(under: dir)
        }
        let closing: [ModelContainer] = lock.withLock {
            let mine = held.filter { container in
                container.configurations.contains { config in
                    guard let store = storeDirectory(config.url) else { return false }
                    return isInside(store, root)
                }
            }
            held.removeAll { c in mine.contains { $0 === c } }
            return mine
        }
        if #available(macOS 15, *) {
            for container in closing { container.deleteAllData() }
        }
        return openFiles(under: dir)
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
