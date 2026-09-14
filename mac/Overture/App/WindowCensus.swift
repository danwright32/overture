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

    // One window as this census reads it. Three properties, because those are the three the answer turns
    // on, and they are the three #334 already chose.
    //
    // A value type rather than `NSWindow`, so the rule below can be exhausted by a test. A hosted test
    // cannot produce a VISIBLE `NSWindow` at all: a window becomes visible by being ordered front, and
    // ordering one front crashes the shared app host (#3480), so a test driving real windows could only
    // ever see `isVisible == false` and would agree with any rule whatsoever (L196, L159).
    struct Window: Equatable, Sendable {
        let isVisible: Bool
        let canBecomeMain: Bool
        let isTitled: Bool

        // `nonisolated` for the same reason as the predicate below: three Bools, no AppKit. The
        // `NSWindow` initialiser beside it is NOT, because reading a window's properties is main actor
        // work, and that is exactly the line this split exists to keep separate.
        nonisolated init(isVisible: Bool, canBecomeMain: Bool, isTitled: Bool) {
            self.isVisible = isVisible
            self.canBecomeMain = canBecomeMain
            self.isTitled = isTitled
        }

        init(_ window: NSWindow) {
            self.init(isVisible: window.isVisible,
                      canBecomeMain: window.canBecomeMain,
                      isTitled: window.styleMask.contains(.titled))
        }
    }

    // A window a person could be LOOKING AT, and the ONE definition of that in this app.
    //
    // `nonisolated`, here and on the two below, because none of them touches AppKit: they read three
    // Bools off a value type. Only the adapter that asks `NSApplication` for its window list is
    // main actor work, and leaving the rule isolated with it would have made every test of the rule
    // main actor too, on a suite that already measures its own main actor share.
    //
    // NOT every visible window, and that correction is #3788's. `MenuBarExtra` is backed by an
    // `NSStatusItem`, and its `NSStatusBarWindow` is in `NSApplication.shared.windows` reporting
    // `isVisible == true` for the whole life of the process. Overture inserts its `MenuBarExtra` on every
    // real launch (`AppEnvironment.showsMenuBarExtra` is false only under test), so a census of visible
    // windows was never zero and `WindowPresence.none` was UNREACHABLE in the shipped app. Every one of
    // the 77 records written by the first build carrying that field says `windows: open`, while System
    // Events reported zero windows for the same process.
    //
    // THE RULE IS NOT NEW, and that is the part worth keeping. #334 needed this exact separation for the
    // Dock presence decision and got it right, in `AppDelegate.isMainContentWindow`, whose comment says in
    // so many words that it excludes "the menu-bar item". This census was written beside it and asked the
    // same question a second, weaker way. So the predicate moved here and `AppDelegate` calls it: finding
    // the right place to put a rule is not the same as checking whether it already exists, and the second
    // copy is the one that was wrong (L655, L263).
    //
    // MEASURED rather than reasoned: `scripts/what-counts-as-a-window.sh` builds a bare AppKit process and
    // reads its window list. A status item is `visible=true canBecomeMain=false titled=false`; an ordinary
    // content window is `visible=true canBecomeMain=true titled=true`. Run it rather than trusting this
    // sentence (L316).
    //
    // NOT filtered by window LEVEL, though a level filter also separates today's two cases. The level says
    // where a window is stacked; these three say what it IS, and the question here is whether a person
    // could be reading something, which is a property of the window rather than of its z-order.
    nonisolated static func isContentWindow(_ window: Window) -> Bool {
        window.isVisible && window.canBecomeMain && window.isTitled
    }

    nonisolated static func visibleCount(among windows: [Window]) -> Int {
        windows.filter(isContentWindow).count
    }

    // The adapter, and the only line that touches AppKit. Deliberately one expression: everything it could
    // get wrong is in the predicate above, where a test can reach it.
    static func visibleCount(in app: NSApplication = .shared) -> Int {
        visibleCount(among: app.windows.map(Window.init))
    }

    nonisolated static func presence(among windows: [Window]) -> WindowPresence {
        WindowPresence.from(visibleWindowCount: visibleCount(among: windows))
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
