import SwiftUI

// #1085: the reply-classify run's single run-level "N of M", shown once at the top of the queue instead of
// repeated on every recipient row the run is drafting (DraftReviewView dropped it from its per-recipient
// label, since the count is one run-wide fact). What the line SAYS is the pure, tested
// ReplyClassifyProgressDecoder.runningLabel, never a sentence assembled here in the view.
//
// #1923: its own view, not a @ViewBuilder property of QueueView. Two reasons, and both matter.
//
// The first is the timer. This used to be a bare TimelineView ticking once a second for as long as the
// window was open, and every tick stat'ed the run marker to find out whether a run was alive. Nothing
// renders here now unless DetachedRunActivity says a run is in flight, so an idle queue runs no timer at
// all: no tick, no stat, nothing. While a run IS live the tick is exactly what it was, re-reading the
// progress so the count advances and the whole line vanishes the moment the run ends, rather than a value
// captured at the last render sitting stale beside a run that has already finished (#1003).
//
// The second is where the observation lands. A @ViewBuilder property is inlined into its parent's body, so
// reading `activity.isRunning` there would have made a run starting or ending re-derive the entire store,
// which is the exact cost #1774 and #1922 removed. Held here, a run flipping repaints one line.
struct ReplyRunLine: View {
    let activity: DetachedRunActivity

    var body: some View {
        if activity.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                // Still passed through `running:` rather than assumed by the `if` above: that guard is what
                // keeps the progress file (an open plus a JSON decode) from being read when there is
                // nothing to report, and #1917 is the issue about it being read anyway.
                if let line = ReplyClassifyProgressDecoder.runningLabel(
                    running: activity.isRunning,
                    progress: ReplyClassifyProgressDecoder.loadCurrent()) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(line).font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
                    }
                }
            }
        }
    }
}
