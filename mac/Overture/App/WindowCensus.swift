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
    @discardableResult
    static func observe(_ stamp: @escaping @MainActor (WindowPresence) -> Void) -> [NSObjectProtocol] {
        stamp(presence())
        let centre = NotificationCenter.default
        let recount: (Notification) -> Void = { _ in
            DispatchQueue.main.async { stamp(presence()) }
        }
        return [
            centre.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main,
                               using: recount),
            centre.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main,
                               using: recount),
        ]
    }
}
