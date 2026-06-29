import SwiftUI

// A spinner paired with a live, ticking elapsed counter so a detached action (reply drafter, Prep,
// scout, Gmail connect, send) reads as working / still-alive rather than a frozen indefinite spinner
// (#435). Shared across every long-action surface so they tell the same working-vs-hung story (#436).
//
// When a `timeout` is supplied and the run passes it, the label flips to a visually distinct "looks
// stuck" state with an optional Retry, so the three required states — working, still-alive, stalled —
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        switch liveness(now: now) {
        case .stalled(let elapsed):
            stalled(elapsed: elapsed)
        case .running, .idle:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                styled(Text(RunProgress.spinnerLabel(base, since: since, now: now)))
            }
        }
    }

    private func liveness(now: Date) -> RunLiveness {
        guard let timeout else {
            // No timeout configured: never stalls, just reflect whether a counter is running.
            return since == nil ? .idle : .running(elapsed: "")
        }
        return RunProgress.liveness(since: since, now: now, timeout: timeout)
    }

    @ViewBuilder private func stalled(elapsed: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.small)
            styled(Text("\(base) looks stuck (\(elapsed))"))
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
