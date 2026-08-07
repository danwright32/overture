import Foundation

// #1810: which KIND of run the shared detached runner just finished.
//
// A reachability check and a Prep run share one runner, one queue file and one results file, and they
// diverge completely at ingest: a check short-circuits before any draft handling, so a Prep run read as a
// check has every draft it wrote discarded, silently. That is #1809, and it happened because the decision
// rested on a side file merely EXISTING, and lived inside a SwiftUI view where nothing could assert it
// (#863).
//
// So the decision moved here, and it stopped being about existence. A marker written BEFORE this run
// started belongs to a run that already ended and cannot speak for this one, which is exactly the shape
// #1809 took: a check's leftover marker sitting there when the next Prep run finished.
enum RunKind: Equatable, Sendable {
    case prep
    case reachabilityCheck

    // The two stamps are taken at slightly different moments (the run's own start is recorded after the
    // marker is written, or the other way about depending on the path), so a marker a few seconds either
    // side of the run's start is still this run's. Only a marker clearly older than the run is refused.
    static let sameRunTolerance: TimeInterval = 120

    /// - Parameters:
    ///   - runStartedAt: when the run now finishing began, if the app recorded it. Nil at a launch-time
    ///     settle of a run this process never watched.
    ///   - probeMarkerStartedAt: the ISO8601 stamp inside the check's marker file, or nil when there is no
    ///     marker at all.
    static func of(runStartedAt: Date?, probeMarkerStartedAt: String?) -> RunKind {
        // No marker: a Prep run. This is the ordinary case AND the safe default, because reading a Prep
        // run as a check is the direction that destroys work.
        guard let stamp = probeMarkerStartedAt else { return .prep }

        // A marker with no run start to compare against is believed. Refusing it would leave a paid check
        // ingesting as a Prep run, which drafts over shows Dan never kept.
        guard let runStartedAt else { return .reachabilityCheck }

        // An unreadable stamp cannot prove the marker is stale, and a marker really is present, so it is
        // believed rather than discarded on a parse failure (L50: never let a failed parse decide by
        // landing on whichever side the comparison happens to give).
        guard let markerStart = ISO8601DateFormatter().date(from: stamp) else { return .reachabilityCheck }

        // Clearly older than this run: it belongs to a run that already ended.
        if markerStart < runStartedAt.addingTimeInterval(-sameRunTolerance) { return .prep }
        return .reachabilityCheck
    }
}
