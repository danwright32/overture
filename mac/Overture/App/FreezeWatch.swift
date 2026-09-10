import Foundation
import Observation

// #3435 Phase 2e: what the app HOLDS, so the watchdog spans a session rather than a screen.
//
// A thin owner, deliberately. Every decision it makes is somewhere testable: what a stall is and what is
// kept are `StallLog`'s, the file is `FreezeLog`'s, the sentence is `FreezeReport`'s, and the measurement
// is `MainThreadWatchdog`'s. What is left here is starting it once and remembering that it started, and
// that second half is the one that matters: a session with no watchdog and a session with no freezes look
// identical from an empty file, and those are the two most different answers available (L98, L11).
@Observable
final class FreezeWatch {
    // Read by the reader, which says a DIFFERENT sentence when this is false. Not derived from the file:
    // the file is empty in both cases.
    private(set) var isWatching = false

    // #3435, and the push gate's lessons check was right to ask: a write that FAILS must not be
    // invisible. `FreezeLog.append` answers false when it cannot write, and discarding that answer would
    // make an unwritable file indistinguishable from a session with no freezes, which is the exact fold
    // this whole design exists to avoid one level up (L11, L13, L95).
    //
    // Counted rather than thrown, because there is nobody to throw to: this runs on the watchdog's queue
    // during a freeze. The count is read by the reader and said in the notice.
    @ObservationIgnored private let failures = FailureCount()

    var writesThatFailed: Int { failures.value }

    final class FailureCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    @ObservationIgnored private var watchdog: MainThreadWatchdog?

    // Idempotent, because the launch task it is called from can run again when the window scene is torn
    // down and rebuilt, and a second watchdog would double every ping (assume it runs twice).
    func start(support: URL) {
        guard watchdog == nil else { return }
        let url = FreezeLog.url(in: support)
        let failures = self.failures
        let watchdog = MainThreadWatchdog(record: { record in
            // Written from the watchdog's own queue. Nothing here touches the main thread, or the record
            // could not be written during the freeze it records.
            if !FreezeLog.append(record, to: url) { failures.bump() }
        })
        self.watchdog = watchdog
        watchdog.start()
        isWatching = true
    }

    func stop() {
        watchdog?.stop()
        watchdog = nil
        isWatching = false
    }

    // Called by the MAIN thread whenever the surface changes. The only writer.
    func stamp(_ surface: StallSurface) { watchdog?.surface.stamp(surface) }

    // #3760: called by the MAIN thread every time it runs a render pass. The only writer.
    //
    // Silently does nothing while the watch is stood down, which is correct rather than a swallow: with
    // no watchdog there is no stall being measured for a pass to belong to. What must not be silent is a
    // pass that happens WHILE the watch is running and is never counted, and that is what
    // `EveryRenderPassIsCountedTests` holds, derived from the source rather than from a rule in prose.
    func recordPass() { watchdog?.passes.bump() }

    // #3439's reader, exposed here so the gate can ask rather than open a file: the longest stall of this
    // session, as the watchdog itself has it, which includes the ones below the storage floor.
    var longestStallThisSession: StallRecord? { watchdog?.snapshot.highWater }
}
