import SwiftUI

// #2091: the queue's line for "Overture stopped watching". What it SAYS is the pure, tested
// WatchGap.line, never a sentence assembled here in the view.
//
// It lives on the queue rather than in a panel Dan has to open, because that is where he triages and a
// callout he has to go looking for is one he never sees. It renders only when there is a silence to
// report, so it is never the line that is always there, and it is drawn in rust like the possible-match
// warning above it: this is not a status, it is Overture saying the quiet on this screen may not be real.
//
// Its own view, not a @ViewBuilder property of QueueView, for the two reasons #1923 established plus one
// of its own.
//
// The #1923 reasons: a property is inlined into its parent's body, so reading the heartbeat there would
// make every tick re-derive the whole store, and the timer this needs would then belong to the parent.
// Held here, a tick repaints one line.
//
// The reason of its own is why there is a timer at all. The heartbeat is written by the scheduler, so a
// view that repainted only when the heartbeat changed could never show that the heartbeat has STOPPED
// changing: the one state it exists to report is the one that produces no event. So it polls, slowly. A
// minute's granularity is far finer than the 90-minute window it is judging, and the read is two doubles
// out of UserDefaults, so an idle queue pays a rounding error rather than the derivation #1774 removed.
struct WatchGapLine: View {
    // Injected so a test can drive a three-day silence without a real one, defaulting to the live
    // readings the app uses. `body` reads the clock from the timeline instead of these.
    var defaults: UserDefaults = .standard
    var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    // Split out of `body` for the same reason LiveRunLabel splits its own (#470): `body` wraps this in a
    // real TimelineView, so inspecting it would mean driving an async timer, and the rendering is exactly
    // what has never been proven when a guard ships into a surface nobody has looked at (L3, and #2098,
    // which exists because a shipped detector's warning was never confirmed to reach the screen).
    @ViewBuilder
    func content(now: Date) -> some View {
        if let report = WatchHeartbeatStore.currentReport(now: now, uptime: uptime, defaults: defaults) {
            Text(WatchGap.line(for: report, now: now))
                .font(.system(size: 11))
                .foregroundStyle(OVColor.rust)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
