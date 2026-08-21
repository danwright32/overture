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

    // #3004: how this kind is spelled in a results file's `runKind` stamp.
    //
    // Deliberately the strings `RunSlot`'s raw values already use, which are the ones written into
    // `prep-run.sh`, `docs/contracts.md` and Dan's Application Support folder. One vocabulary rather than
    // a third: two spellings for one idea are correct read separately and contradict each other in the
    // reading (L118). Built FROM the slot's raw value rather than retyped, so they cannot drift.
    var resultsFileValue: String {
        switch self {
        case .prep: return RunSlot.prep.rawValue
        case .reachabilityCheck: return RunSlot.check.rawValue
        }
    }

    // nil for anything this app does not recognise, which is the same answer an ABSENT stamp gets. A value
    // it cannot read is not a kind, and inventing one from a typo would be a definite claim built out of
    // not knowing (L11).
    init?(resultsFileValue: String) {
        switch resultsFileValue {
        case RunSlot.prep.rawValue: self = .prep
        case RunSlot.check.rawValue: self = .reachabilityCheck
        default: return nil
        }
    }

    // #2614: what Dan calls this run, in ONE place. Five surfaces named the run holding the single slot
    // and three of them said "prep" whatever was going, because they read a boolean that only knew the
    // slot was taken. A shared noun is what stops a sixth phrasing appearing beside them.
    var runNoun: String {
        switch self {
        case .prep: return "prep run"
        case .reachabilityCheck: return "reachability check"
        }
    }

    // The stop control's label. Its own string rather than "Cancel \(runNoun)", so the Prep wording Dan
    // already knows is untouched and neither reads as a sentence fragment.
    var cancelLabel: String {
        switch self {
        case .prep: return "Cancel prep"
        case .reachabilityCheck: return "Cancel reachability check"
        }
    }

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
