import SwiftUI

// A spinner paired with a live, ticking elapsed counter so a detached AI run (reply drafter, Prep,
// scout) reads as working / still-alive rather than a frozen indefinite spinner (#435). The counter
// advances every second via TimelineView; `since` nil falls back to the plain "<base>…" caption.
// Shared across all three run surfaces so they tell the same working-vs-hung story.
struct LiveRunLabel: View {
    let base: String
    let since: Date?
    var font: Font? = nil
    var color: Color? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                caption(now: context.date)
            }
        }
    }

    @ViewBuilder private func caption(now: Date) -> some View {
        let text = RunProgress.spinnerLabel(base, since: since, now: now)
        if let font, let color {
            Text(text).font(font).foregroundStyle(color)
        } else {
            Text(text)
        }
    }
}
