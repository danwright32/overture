import Foundation

// A persistent, human-readable summary of where the Prep pipeline stands, shown in
// the masthead so freshness is visible at a glance (not just a transient toast).
// Pure so it is unit-testable; the view formats the relative time.

struct PrepStatus: Equatable, Sendable {
    var kept: Int          // kept (.queued) with no draft yet — waiting on a Prep run
    var drafted: Int       // have a draft awaiting Dan's review (.drafted)
    var approved: Int      // approved to send (.approved)
    var lastRunStartedAt: Date?
    var running: Bool

    // The one-line summary. Order of precedence: a run in progress, then work waiting,
    // then drafts to review, then a settled "all caught up".
    func summary(now: Date) -> String {
        if running { return "Prepping\(keptSuffix)…" }
        var parts: [String] = []
        if kept > 0 { parts.append("\(kept) to prep") }
        if drafted > 0 { parts.append("\(drafted) to review") }
        if approved > 0 { parts.append("\(approved) approved") }
        if parts.isEmpty { parts.append("All caught up") }
        if let last = lastRunStartedAt {
            parts.append("last prep \(Self.relative(from: last, to: now))")
        }
        return parts.joined(separator: " · ")
    }

    private var keptSuffix: String { kept > 0 ? " \(kept)" : "" }

    // Coarse relative time, enough for "is this fresh?". No external dependency.
    static func relative(from: Date, to: Date) -> String {
        let seconds = max(0, to.timeIntervalSince(from))
        switch seconds {
        case ..<90: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }
}
