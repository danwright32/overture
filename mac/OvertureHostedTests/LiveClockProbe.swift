import Foundation
@testable import Overture

/// Probe instants for the hosted card tests, expressed against the LIVE clock (#3169).
///
/// `ProspectRowView` renders its reachability badge from `item.reachabilityBadge()`, called with no
/// `now`, so it reads the wall clock at render time and there is no seam a hosted test can pin. A
/// fixture written as a fixed instant therefore means "probed on that day", while what these tests mean
/// is "probed recently", and the two agree only until real time walks past
/// `Reachability.probeFreshness`.
///
/// It did. Thirteen tests pinned `Date(timeIntervalSince1970: 1_780_000_000)`, which is
/// 2026-05-28T20:26:40Z, and at 2026-08-26T20:26:40Z that crossed the 90 day window. Eight tests in
/// `ProspectRowViewReachabilityTests` and five in `RecheckControlOnTheRowTests` went red at once, on a
/// main nobody had touched, because every row had started rendering `staleProbeBadge` instead of the
/// badge each test asserts. Only one end of the pair was pinned (L130).
///
/// Both values are derived from `Reachability.probeFreshness` rather than from a chosen number of days,
/// so a change to the window carries the fixtures with it instead of leaving them to be found by a
/// suite going red months later.
enum LiveClockProbe {

    /// An instant the live clock still calls current, whenever this runs.
    ///
    /// Half the window rather than a day, so a fixture is nowhere near either edge: a value a few hours
    /// inside the boundary would rot again the moment anything nudged the window.
    static var fresh: Date { Date().addingTimeInterval(-Reachability.probeFreshness / 2) }

    /// An instant the live clock has already released, whenever this runs.
    static var stale: Date { Date().addingTimeInterval(-Reachability.probeFreshness * 2) }
}
