import SwiftUI

// #4338 (A10): the masthead's landing line, where a scout landing's progress is shown between scouts, in the
// state it is in: working, alive, stalled, failed, or finished (`LandingLook`), each drawn its own way so no two
// read alike (Dan's rule, 2026-06-28).
//
// Its own view, reading its own observable models (`LandingMarker`, `EntryFlushRecord`), for #1923's reason: a
// landing starting or saying something redraws this line and nothing else on the masthead. It draws nothing at
// all on the ordinary day, so a quiet app adds no rows (#2204).
//
// Only a landing in progress ticks, and only while it waits its turn for the store: the landing block itself
// cannot redraw (the honest limit in `LandingProgress.swift`), so it shows its start time instead.
struct LandingLine: View {
    var marker: LandingMarker = .shared
    var flushes: EntryFlushRecord = .shared
    var flight: LandingSingleFlight = .shared
    var handlers: LandingLineHandlers

    struct Confirmation: Identifiable {
        let action: LandingAction
        let title: String
        let message: String
        var id: String { title + message }
    }

    @State private var confirming: Confirmation?

    var body: some View {
        let stuck = flushes.isStuck ? (rows: flushes.rows, lastTryFailedAt: flushes.lastTryFailedAt) : nil
        let standing = marker.standing(editsStuck: stuck)
        let latest = marker.latestNotStanding(standing)
        let live = marker.live
        Group {
            if !standing.isEmpty || live != nil || !latest.isEmpty {
                VStack(alignment: .leading, spacing: OVSpacing.xxs) {
                    ForEach(Array(standing.enumerated()), id: \.offset) { _, outcome in row(outcome, counter: nil) }
                    if let live { liveRow(live) }
                    ForEach(Array(latest.enumerated()), id: \.offset) { _, outcome in row(outcome, counter: nil) }
                }
            }
        }
        .confirmationDialog(confirming?.title ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { confirmation in
            Button("Discard", role: .destructive) { handlers.perform(confirmation.action) }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    // A landing in progress, re-read every second: whether it is waiting in the queue, and how long it has run.
    private func liveRow(_ live: LandingMarker.Live) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let queue = queuePosition(live)
            let shown = LandingOutcome.live(live.work, startedAt: live.startedAt, now: context.date,
                                            waiting: queue.waiting, holder: queue.holder)
            row(shown.outcome, counter: shown.counter)
        }
    }

    // Whether this landing is waiting its turn for the store, and who holds it, read from the landing queue itself.
    private func queuePosition(_ live: LandingMarker.Live) -> (waiting: Bool, holder: LandingSingleFlight.EntryPoint?) {
        #if DEBUG
        if let preview = marker.previewWaitingBehind { return (true, preview) }
        #endif
        return (flight.queue.contains(live.work.entryPoint), flight.holder?.entryPoint)
    }

    private func row(_ outcome: LandingOutcome, counter: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: OVSpacing.xs) {
            LandingMark(look: outcome.look)
            Text(outcome.line)
                .font(.system(size: 11))
                .foregroundStyle(LandingMark.textColor(outcome.look))
                .fixedSize(horizontal: false, vertical: true)
            if let counter {
                Text(counter).font(.system(size: 11)).monospacedDigit().foregroundStyle(OVColor.inkFaint)
            }
            ForEach(outcome.actions, id: \.self) { action in
                Button(action.title) { press(action) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(action.isDestructive ? OVColor.rust : OVColor.forestText)
            }
            Spacer(minLength: 0)
        }
    }

    // A control that gives something up asks first, with what it will change derived now (L180); the others act.
    private func press(_ action: LandingAction) {
        guard let title = action.confirmationTitle else {
            handlers.perform(action)
            return
        }
        confirming = Confirmation(action: action, title: title, message: handlers.consequence(action))
    }
}

// #4338: the mark beside a landing outcome, one per look, so the five never read alike at a glance and never by
// colour alone (L49): a spinner for work under way, a clock for something still coming, a warning symbol for a
// stall, a cross for a failure, and a tick for done. Shared by the landing line and the scout summary, so a look
// is drawn one way wherever it appears. Decorative, since the sentence beside it says the same, so a screen reader
// hears the sentence alone.
struct LandingMark: View {
    let look: LandingLook

    var body: some View {
        switch look {
        case .working:
            ProgressView().controlSize(.mini).tint(OVColor.gold).accessibilityHidden(true)
        case .alive:
            symbol("clock", OVColor.inkSoft)
        case .stalled:
            symbol("exclamationmark.triangle.fill", OVColor.rust)
        case .failed:
            symbol("xmark.circle.fill", OVColor.rust)
        case .finished:
            symbol("checkmark", OVColor.forestText)
        }
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color).accessibilityHidden(true)
    }

    static func textColor(_ look: LandingLook) -> Color {
        switch look {
        case .working, .alive: return OVColor.inkSoft
        case .stalled: return OVColor.ink
        case .failed: return OVColor.rust
        case .finished: return OVColor.inkFaint
        }
    }
}

// What the landing line's controls do, handed in by RootView, which owns the store and the landing folders.
struct LandingLineHandlers {
    var perform: (LandingAction) -> Void
    // What a confirmation will say, derived from the state at the moment it is asked for (L180).
    var consequence: (LandingAction) -> String

    // For a surface built without RootView (a test's queue): the line still draws, and its controls do nothing.
    // RootView's own call is held to passing real handlers by `LandingLineWiringTests`.
    static var unwired: LandingLineHandlers { LandingLineHandlers(perform: { _ in }, consequence: { _ in "" }) }
}
