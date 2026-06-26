import Foundation

// Watches the Downbeat export file and emits debounced change ticks, so a booking made in
// Downbeat while Overture is open surfaces as Booked without a relaunch or scout (#197).
// The caller consumes `changes()` and runs the same reconcile path as launch.
//
// Why a watcher and not a poll: Downbeat rewrites this file at most a few times a day, so a
// passive FS source is cheaper and more responsive than a timer. The plumbing below (a
// DispatchSource on the file descriptor) is inherently IO and is not unit-tested; the one
// decision worth testing in isolation, `shouldReconcile`, is split out and covered by
// DownbeatExportWatcherTests.
//
// Concurrency: every piece of mutable state (the source, the pending debounce work) is
// touched only on `queue`, a private serial DispatchQueue. arm(), stop(), and the event
// handler all run on it, so there is no cross-thread shared mutable state. Nothing ever
// blocks: there is no semaphore, no `.wait()`, no `sync` bridge (a past send-path deadlock
// came from exactly that). Ticks reach the caller through a Sendable AsyncStream
// continuation; the caller does the actual reconcile on the main actor.
final class DownbeatExportWatcher: @unchecked Sendable {
    // Pure change gate: only reconcile when the file's modification date actually moved.
    // A noisy filesystem can deliver an event for an unchanged file (e.g. an attribute
    // touch); without this we would refetch and re-save for nothing. A nil current date
    // (file gone or unreadable) means there is nothing to reconcile from.
    static func shouldReconcile(previous: Date?, current: Date?) -> Bool {
        guard let current else { return false }
        return current != previous
    }

    private let url: URL
    private let debounce: TimeInterval
    private let maxArmRetries: Int
    private let queue = DispatchQueue(label: "com.danwright.overture.downbeat-watcher")
    private let continuation: AsyncStream<Void>.Continuation

    private var source: (any DispatchSourceFileSystemObject)?
    private var pending: DispatchWorkItem?

    private init(url: URL, debounce: TimeInterval, maxArmRetries: Int,
                 continuation: AsyncStream<Void>.Continuation) {
        self.url = url
        self.debounce = debounce
        self.maxArmRetries = maxArmRetries
        self.continuation = continuation
    }

    // A stream of debounced change ticks for the export file. The watcher tears itself down
    // when the consuming task ends (cancelled or finished), via the stream's onTermination.
    static func changes(url: URL = DownbeatBridge.defaultURL,
                        debounce: TimeInterval = 0.75,
                        maxArmRetries: Int = 5) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let watcher = DownbeatExportWatcher(url: url, debounce: debounce,
                                                maxArmRetries: maxArmRetries,
                                                continuation: continuation)
            watcher.queue.async { watcher.arm(retriesLeft: maxArmRetries) }
            continuation.onTermination = { _ in
                watcher.queue.async { watcher.stop() }
            }
        }
    }

    // MUST run on `queue`. Opens the file read-only-for-events and starts a FS-object source.
    // If the file is not there yet, retries briefly: an atomic replace (Downbeat writes a temp
    // file then renames it onto the path) leaves a tiny window where the path has no inode.
    // Exhausting the retries just stops watching; the launch reconcile and the next scout
    // still cover that gap.
    private func arm(retriesLeft: Int) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            if retriesLeft > 0 {
                queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.arm(retriesLeft: retriesLeft - 1)
                }
            }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue)
        source = src
        src.setEventHandler { [weak self] in
            self?.handleEvent()
        }
        // Closing the descriptor is the cancel handler's job, so it survives a re-arm that
        // has already replaced `source` with a new source on a new descriptor.
        src.setCancelHandler { close(fd) }
        src.resume()
    }

    // MUST run on `queue` (the source's target queue, so reads of `source` are race-free).
    private func handleEvent() {
        let flags = source?.data ?? []
        // An atomic replace invalidates this descriptor (it points at the now-unlinked old
        // inode), so a plain re-watch would go deaf after the first rewrite. Tear down and
        // re-open the path to follow the new inode, and still emit a tick for the change.
        if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
            teardownSource()
            scheduleTick()
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                self.arm(retriesLeft: self.maxArmRetries)
            }
        } else {
            scheduleTick()
        }
    }

    // MUST run on `queue`. Coalesce a burst of events (a write often arrives as several) into
    // a single tick once things go quiet for `debounce` seconds.
    private func scheduleTick() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.continuation.yield(())
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    // MUST run on `queue`. Cancelling the source runs its cancel handler, which closes the fd.
    private func teardownSource() {
        source?.cancel()
        source = nil
    }

    // MUST run on `queue`.
    private func stop() {
        pending?.cancel()
        pending = nil
        teardownSource()
    }
}
