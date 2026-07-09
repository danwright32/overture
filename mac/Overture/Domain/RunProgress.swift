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
    // as in-progress. `detail` (#354, e.g. "3 of 9" from a run's own progress file) inserts before the
    // ellipsis when present: "Prepping 3 of 9… 0:45".
    static func spinnerLabel(_ base: String, since start: Date?, now: Date, detail: String? = nil) -> String {
        let label = detail.map { "\(base) \($0)" } ?? base
        if let elapsed = elapsedLabel(since: start, now: now) {
            return "\(label)… \(elapsed)"
        }
        return "\(label)…"
    }

    // #436: the single three-state decision every long action routes through. Given the run's start,
    // the current instant, and its expected window, report whether the run is idle, still working/alive
    // (with the elapsed counter), or past its timeout and stalled (an actionable failed state, not an
    // indefinite spinner). The boundary is `>=` so it matches Recipient.isReplyDraftStalled.
    //
    // #471: a fixed wall-clock timeout alone can't tell a genuinely dead run from one that's just
    // slower than usual. `runAlive`, when supplied, is the run's real heartbeat (e.g. a marker-freshness
    // check); `true` overrides a past-timeout result to `.running` instead of `.stalled`. Default nil
    // keeps every existing caller's behavior (wall-clock only) unchanged.
    static func liveness(since start: Date?, now: Date, timeout: TimeInterval, runAlive: Bool? = nil) -> RunLiveness {
        guard let start, let elapsed = elapsedLabel(since: start, now: now) else { return .idle }
        if now.timeIntervalSince(start) >= timeout {
            return runAlive == true ? .running(elapsed: elapsed) : .stalled(elapsed: elapsed)
        }
        return .running(elapsed: elapsed)
    }
}

// The three visibly-distinct states the saved UX principle requires of any non-instant action:
// nothing in flight, working/still-alive, or stalled/failed. Carries the elapsed counter on both live
// states so the stalled case still shows how long it has been stuck.
//
// #472: a deliberately different, narrower vocabulary from DetachedRunPhase
// (DetachedRunOutcome.swift), not an oversight. This answers "what should the UI show right now
// while something might still be in flight" (a continuous, per-second question, driving
// LiveRunLabel); DetachedRunPhase answers "the moment a detached run stopped, what did it
// produce" (a one-shot terminal question). Evaluated folding them into one vocabulary per #472
// and deliberately didn't: the two are used in disjoint call sites for different lifecycle
// moments, so a single flat enum would just give each side dead cases it can never see.
enum RunLiveness: Equatable {
    case idle
    case running(elapsed: String)
    case stalled(elapsed: String)
}
