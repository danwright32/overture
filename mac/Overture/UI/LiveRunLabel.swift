import SwiftUI

// A spinner paired with a live, ticking elapsed counter so a detached action (reply drafter, Prep,
// scout, Gmail connect, send) reads as working / still-alive rather than a frozen indefinite spinner
// (#435). Shared across every long-action surface so they tell the same working-vs-hung story (#436).
//
// When a `timeout` is supplied and the run passes it, the label flips to a visually distinct "looks
// stuck" state with an optional Retry, so the three required states (working, still-alive, stalled)
// are all distinguishable instead of one identical spinner (saved UX principle). The counter advances
// every second via TimelineView; `since` nil falls back to the plain "<base>…" caption.
struct LiveRunLabel: View {
    let base: String
    let since: Date?
    // The run's expected window; nil keeps the legacy behaviour (spinner + counter, never stalls).
    var timeout: TimeInterval? = nil
    var font: Font? = nil
    var color: Color? = nil
    // Shown alongside the stalled state when provided; tapping it re-launches the run.
    var onRetry: (() -> Void)? = nil
    // #354: real "N of M" progress (e.g. from a run's own progress file), inserted before the
    // ellipsis. nil when the run has no progress data to show.
    // #1003: a closure (not a plain String) so it re-reads the run's progress on every TimelineView
    // tick, exactly as `runAlive` does, rather than reflecting a value the enclosing view captured at
    // ITS last render (which no timer drives). Otherwise the count could sit stale for minutes beside
    // an elapsed counter that keeps moving, reading as "alive and progressing" whether or not it was.
    var progressDetail: (() -> String?)? = nil
    // #471: the run's real heartbeat (e.g. marker freshness), re-checked on every tick so a past-timeout
    // run that's still genuinely alive never flips to the misleading "looks stuck" state. A closure
    // (not a plain Bool) so it re-evaluates each second alongside the TimelineView tick. nil keeps the
    // wall-clock-only behavior.
    var runAlive: (() -> Bool)? = nil
    // #994: icon only, with the sentence moved to the tooltip. For the toolbar, where a label that
    // grows when a run starts reflows every other item and pushes real buttons into the macOS ">>"
    // overflow, at the exact moment Dan is watching for the run to start. Off everywhere else: the
    // reply drafter, Prep and Gmail connect all have room for the words.
    var compact: Bool = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    // #470: internal (not private) so LiveRunLabelViewStateTests can call this directly with a
    // fixed `now`, inspecting the result with ViewInspector, instead of driving the real
    // TimelineView `body` wraps this in asynchronously.
    @ViewBuilder func content(now: Date) -> some View {
        let state = liveness(now: now)
        if compact {
            compactContent(state: state, now: now)
        } else {
            switch state {
            case .stalled(let elapsed):
                stalled(elapsed: elapsed)
            case .running, .idle:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    styled(Text(RunProgress.spinnerLabel(base, since: since, now: now,
                                                         detail: progressDetail?())))
                }
            }
        }
    }

    // #994: the same three states, told by ICON alone, so the item's width never changes and the
    // toolbar never reflows. This is not the "bare indefinite spinner" the progress rule forbids: a run
    // that passes its timeout without a heartbeat flips to the warning symbol, so working, still-alive
    // and stalled all stay distinguishable at a glance. Only the numbers move to the tooltip.
    @ViewBuilder private func compactContent(state: RunLiveness, now: Date) -> some View {
        switch state {
        case .stalled:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.small)
                .help(helpText(now: now))
        case .running, .idle:
            ProgressView()
                .controlSize(.small)
                .help(helpText(now: now))
        }
    }

    // #994: the sentence the tooltip says, which in compact mode is the ONLY place the elapsed counter
    // and the "N of M" progress appear. Internal and pure so a test can read it at a fixed `now`,
    // rather than the words being buried in a modifier no test can see.
    func helpText(now: Date) -> String {
        switch liveness(now: now) {
        case .stalled(let elapsed):
            return RunProgress.stalledLabel(base, elapsed: elapsed)
        case .running, .idle:
            return RunProgress.spinnerLabel(base, since: since, now: now, detail: progressDetail?())
        }
    }

    private func liveness(now: Date) -> RunLiveness {
        guard let timeout else {
            // No timeout configured: never stalls, just reflect whether a counter is running.
            return since == nil ? .idle : .running(elapsed: "")
        }
        return RunProgress.liveness(since: since, now: now, timeout: timeout, runAlive: runAlive?())
    }

    @ViewBuilder private func stalled(elapsed: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.small)
            styled(Text(RunProgress.stalledLabel(base, elapsed: elapsed)))
            if let onRetry {
                Button("Retry", action: onRetry)
                    .controlSize(.small)
                    .buttonStyle(.link)
            }
        }
    }

    private func styled(_ text: Text) -> Text {
        var t = text
        if let font { t = t.font(font) }
        if let color { t = t.foregroundStyle(color) }
        return t
    }
}
