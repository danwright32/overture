import Foundation

// The single-writer guard for the local SwiftData store (#264 / Phase 0 of #237). A BSD `flock` on a
// lockfile beside the store: because flock conflicts across separate open file descriptions (even
// within one machine), a second Overture process that tries to acquire it is refused. This is the
// REAL guarantee that two processes never open the same store file — LaunchServices bundle-id dedup is
// not trusted. The descriptor is held for the process lifetime; releasing frees the lock.
final class StoreLock {
    private let fd: Int32
    private var released = false

    private init(fd: Int32) { self.fd = fd }

    // Acquire a non-blocking exclusive lock on the lockfile. Returns nil if another process holds it
    // (or the file can't be opened), so the caller degrades instead of opening the store.
    static func acquire(at url: URL) -> StoreLock? {
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        return StoreLock(fd: fd)
    }

    func release() {
        guard !released else { return }
        released = true
        flock(fd, LOCK_UN)
        close(fd)
    }

    deinit { release() }
}
