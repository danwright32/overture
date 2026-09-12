import Foundation

// #3796: the app's once-an-hour tick, lifted out of `RootView`'s `.task` so what it does can be exercised
// without waiting an hour.
//
// The loop itself moved rather than being copied. `RootView` held `while !Task.isCancelled { try? await
// Task.sleep(...) ; work() }` inline, which is a delay with no seam in it: every test that wanted to know
// what a tick does had to wait out the real hour, so nothing ever asked (L524). The sleep, the cancellation
// reading and the interval are all injectable here, and the real ones are the defaults, so the app keeps
// the behaviour it had and a test never waits.
enum HourlyMaintenance {
    // WHY AN HOUR, and why this loop rather than the minute one beside it in `RootView`. The work on this
    // tick is bookkeeping over files that only change when something unusual happens: a freeze log that
    // grows only when the main thread actually stalls, and a scout schedule that comes due once a day.
    // Compaction READS AND REWRITES those files, so putting it on the minute loop would be 60 rewrites an
    // hour of a file that changed on none of them, and the minute loop's own work (re-reading a register
    // of unreadable files) is a dictionary lookup chosen precisely because it costs nothing to repeat.
    // An hour is long enough that the rewrite is free and short enough that a resident app's log is
    // bounded within the session rather than at the next login, which is the whole of #3796.
    static let intervalSeconds: TimeInterval = 60 * 60

    // Sleep, then work, until cancelled.
    //
    // `isCancelled` is read AGAIN after the sleep. A cancelled `Task.sleep` returns AT ONCE rather than
    // throwing out of this loop, so without that second reading the window's teardown buys one last full
    // tick on the way out: a file read and rewrite at the moment the thing that owns it is going away.
    @MainActor
    static func run(intervalSeconds: TimeInterval = HourlyMaintenance.intervalSeconds,
                    sleep: @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
                    isCancelled: @MainActor () -> Bool = { Task.isCancelled },
                    tick: @MainActor () -> Void) async {
        while !isCancelled() {
            await sleep(intervalSeconds)
            guard !isCancelled() else { return }
            tick()
        }
    }
}
