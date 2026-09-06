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

    @ObservationIgnored private var watchdog: MainThreadWatchdog?

    // Idempotent, because the launch task it is called from can run again when the window scene is torn
    // down and rebuilt, and a second watchdog would double every ping (assume it runs twice).
    func start(support: URL) {
        guard watchdog == nil else { return }
        let url = FreezeLog.url(in: support)
        let watchdog = MainThreadWatchdog(record: { record in
            // Written from the watchdog's own queue. Nothing here touches the main thread, or the record
            // could not be written during the freeze it records.
            FreezeLog.append(record, to: url)
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

    // #3439's reader, exposed here so the gate can ask rather than open a file: the longest stall of this
    // session, as the watchdog itself has it, which includes the ones below the storage floor.
    var longestStallThisSession: StallRecord? { watchdog?.snapshot.highWater }
}
