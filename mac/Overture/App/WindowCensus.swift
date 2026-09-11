import AppKit
import Foundation

// #3788: how the main thread learns whether any window is on screen, so a stall record can say whether
// anybody could have been looking at it.
//
// NOT `scenePhase`. `RootView` stands the watchdog down on `.background`, whose comment says that for this
// scene "the window is gone", and measured 2026-09-11 that is false of this app: with System Events
// reporting zero windows the watchdog had been running for two hours. Overture is resident in the menu bar
// (installed as a login agent), so the scene outlives the window and a premise written when this was an
// ordinary windowed app has been quietly wrong ever since.
//
// Its own type rather than a method on `FreezeWatch`, which is deliberately a thin owner holding no AppKit
// and making no decisions of its own.
@MainActor
enum WindowCensus {

    // Every window this app has that is actually on screen. A panel, a sheet and the main window all count,
    // because the question is whether anything could be looked at rather than which thing it is.
    static func visibleCount(in app: NSApplication = .shared) -> Int {
        app.windows.filter(\.isVisible).count
    }

    static func presence(in app: NSApplication = .shared) -> WindowPresence {
        WindowPresence.from(visibleWindowCount: visibleCount(in: app))
    }

    // Stamps once now, then on every window appearing or disappearing.
    //
    // BOTH DIRECTIONS, and the guard beside this holds it: a census registered for closings alone reports
    // `.none` for ever after the first window closes, and one registered for openings alone reports `.open`
    // for ever, and either is worse than no field at all because it looks authoritative.
    //
    // TAKEN ON THE NEXT RUN LOOP TURN, never inside the handler. `willClose` fires BEFORE the window goes, so
    // a census inside it still counts the closing window and the last window closing would read as one still
    // open. Deferring avoids that arithmetic rather than doing it, which is why this hop is load bearing and
    // not a pointless one to be tidied away later.
    // RUNS UNTIL CANCELLED, and removes its observers on the way out.
    //
    // `NotificationCenter.default` outlives every view and keeps the blocks alive whether or not anybody
    // holds the token, so an observer registered and not removed is PERMANENT rather than dead. `RootView`'s
    // launch task runs more than once (`FreezeWatch.start` is documented as idempotent for exactly that
    // reason: the window scene can be torn down and rebuilt), so each rebuild would leave another pair
    // dispatching on every window event for the life of a resident process. The value would stay correct
    // throughout, because stamping the same presence twice is harmless, which is what would have made it
    // invisible (L86).
    //
    // Shaped as an awaiting call rather than a returned token list, so the caller CANNOT discard the thing
    // that does the cleanup: the `.task` it sits in cancels on teardown and the `defer` runs. A token list is
    // what the first version returned, and the call site dropped it.
    static func observeUntilCancelled(_ stamp: @escaping @MainActor (WindowPresence) -> Void) async {
        stamp(presence())
        let centre = NotificationCenter.default
        let recount: (Notification) -> Void = { _ in
            DispatchQueue.main.async { stamp(presence()) }
        }
        // A lock-guarded box, on `MainThreadWatchdog.SurfaceBox`'s precedent and for a related reason: the
        // cancellation closure below is `@Sendable` and cannot capture `[any NSObjectProtocol]` directly.
        let tokens = TokenBox([
            centre.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main,
                               using: recount),
            centre.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main,
                               using: recount),
        ])
        // NO TIMER. Written first as `while !Task.isCancelled { await Task.sleep(60s) }`, which works and adds
        // a wake-up every minute, for the whole life of a resident process, to an app under investigation for
        // doing work while nobody is looking (#3788). The loop was pattern-matched off the two neighbouring
        // loops in `RootView` rather than asked for by anything here.
        //
        // `withTaskCancellationHandler` suspends with nothing scheduled and removes the observers when the
        // enclosing task is cancelled, which is what teardown does.
        await withTaskCancellationHandler {
            await Self.suspendUntilCancelled()
        } onCancel: {
            for token in tokens.take() { centre.removeObserver(token) }
        }
    }

    // Holds the observer tokens across the cancellation boundary. `take()` rather than a getter, so the
    // removal cannot run twice: a second `removeObserver` on a token already removed is not a crash, but a box
    // that hands the same tokens out for ever invites one to be removed after its notification centre has
    // moved on.
    final class TokenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [NSObjectProtocol]
        init(_ tokens: [NSObjectProtocol]) { self.tokens = tokens }
        func take() -> [NSObjectProtocol] {
            lock.withLock {
                let held = tokens
                tokens = []
                return held
            }
        }
    }

    // Suspends for as long as the task lives. Not a wait for a condition and not a poll: there is nothing to
    // check, because the only thing that ends it is cancellation, which resumes this directly.
    private static func suspendUntilCancelled() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try? await Task.sleep(nanoseconds: UInt64.max)
            }
            await group.waitForAll()
        }
    }
}
