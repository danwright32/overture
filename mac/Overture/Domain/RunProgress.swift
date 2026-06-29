import Foundation

// The positive "still alive" signal for a detached AI run (#435): elapsed time since the run was
// requested, formatted for the spinner ("Drafting a reply… 0:45"). Shared by the reply drafter, Prep,
// and scout so a working / still-alive run reads differently from a bare indefinite spinner. Pure: the
// view feeds it a start time and the current instant from a TimelineView; this only formats.
enum RunProgress {
    static func elapsedLabel(since start: Date?, now: Date) -> String? {
        guard let start else { return nil }
        let total = max(0, Int(now.timeIntervalSince(start)))   // clamp clock skew to zero, never negative
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    // The full spinner caption: "Drafting a reply… 0:45" while a start time is known, or the plain
    // "Drafting a reply…" when it isn't. The trailing ellipsis stays so a counter-less run still reads
    // as in-progress.
    static func spinnerLabel(_ base: String, since start: Date?, now: Date) -> String {
        if let elapsed = elapsedLabel(since: start, now: now) {
            return "\(base)… \(elapsed)"
        }
        return "\(base)…"
    }
}
