import Testing
import Foundation
@testable import Overture

// #197: when Downbeat rewrites its export while Overture is open, the watcher fires a
// reconcile so a fresh booking surfaces without a relaunch or scout. The raw FS-event
// plumbing is IO and not unit-tested; the change gate (shouldReconcile) is the one pure
// decision worth pinning down, since a noisy filesystem can deliver events that did not
// actually change the file.
@Suite("Downbeat export watcher change gate")
struct DownbeatExportWatcherTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000_000)

    @Test func reconcilesWhenNoPriorModificationDateButFilePresent() {
        // First observed write after launch saw no file (or no date yet): reconcile.
        #expect(DownbeatExportWatcher.shouldReconcile(previous: nil, current: t0) == true)
    }

    @Test func reconcilesWhenModificationDateAdvances() {
        let later = t0.addingTimeInterval(5)
        #expect(DownbeatExportWatcher.shouldReconcile(previous: t0, current: later) == true)
    }

    @Test func reconcilesWhenModificationDateChangesEvenIfEarlier() {
        // A restore could move the date backwards; any change still means new content.
        let earlier = t0.addingTimeInterval(-5)
        #expect(DownbeatExportWatcher.shouldReconcile(previous: t0, current: earlier) == true)
    }

    @Test func skipsWhenModificationDateIsUnchanged() {
        // A spurious event (attribute touch) on an unchanged file must not reconcile.
        #expect(DownbeatExportWatcher.shouldReconcile(previous: t0, current: t0) == false)
    }

    @Test func skipsWhenFileHasNoCurrentModificationDate() {
        // File vanished or its date is unreadable: nothing to reconcile from.
        #expect(DownbeatExportWatcher.shouldReconcile(previous: t0, current: nil) == false)
        #expect(DownbeatExportWatcher.shouldReconcile(previous: nil, current: nil) == false)
    }
}
