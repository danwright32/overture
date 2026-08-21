import Foundation

// #2884: what the OmniFocus settings pane says about the last failure, decided outside the view.
//
// `omniFocusLastSyncError` has always held the real text, and answering "why is it failing?" on
// 2026-08-17 required `defaults read com.danwright.overture`. The masthead line says which KIND of
// failure it is, in Dan's words; this is the raw text OmniFocus or AppleScript produced, which is what a
// diagnosis needs and where there is room for it.
//
// A function rather than logic in the view, for a reason the suite enforces: a test may not reach
// `UserDefaults.standard` (#2540, L2), and a view reading `@AppStorage` can only be driven through it. So
// the decision takes its two facts as arguments and the view stays dumb.
enum OmniFocusFailureSection {
    /// The heading, shown only when there is a failure to head.
    static let heading = "Last failure"

    /// The reason to show, or nil when the last sync was clean and the section is not drawn at all.
    ///
    /// A section that rendered a heading over an empty box on a healthy sync would be the shape #1547
    /// was: the explaining half sitting in the branch not taken.
    static func reasonLine(failedAt: Double, storedReason: String) -> String? {
        guard failedAt > 0 else { return nil }
        let text = storedReason.trimmingCharacters(in: .whitespacesAndNewlines)
        // A failure recorded with NO reason is its own state and says so, rather than drawing a blank
        // line under the heading: an absence presented as a value is a detection, not a label (L67).
        guard !text.isEmpty else {
            return "OmniFocus sync failed and recorded no reason, which is itself worth reporting."
        }
        return text
    }
}
