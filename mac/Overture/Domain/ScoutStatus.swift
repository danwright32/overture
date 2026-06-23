import Foundation

// When the scout last ran, shown in the masthead so a stale queue is obvious (#35).
// Pure; reuses PrepStatus.relative for the coarse "Xh ago" wording.
struct ScoutStatus: Equatable, Sendable {
    var lastScoutedAt: Date?

    func summary(now: Date) -> String {
        guard let last = lastScoutedAt else { return "Not scouted yet" }
        return "Scouted \(PrepStatus.relative(from: last, to: now))"
    }
}
