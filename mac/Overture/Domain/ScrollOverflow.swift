import Foundation

// #2159: does a height-capped scrolling box have anything left below its bottom edge?
//
// macOS hides scrollbars until a gesture starts, so at rest an overflowing panel and a complete one are
// pixel-identical. Dan found the reply panel's hidden half by trying it, not by being shown (L49, L76),
// and the message he was answering carried a list of season dates below the fold. This comparison is the
// only thing that can tell the two states apart, so it lives here where it is tested rather than inline
// in a view body where nothing could exercise it.
enum ScrollOverflow {

    // Below this, what is left is layout rounding rather than content. A cue for half a point would sit
    // on panels showing everything they have, and a cue that is sometimes wrong is one Dan learns to
    // disregard on the panels that mean it.
    static let roundingTolerance: CGFloat = 2

    /// - Parameters:
    ///   - contentHeight: the full height of everything inside the scroll view.
    ///   - visibleHeight: the height of the window onto it (the cap, or less if the box got less).
    ///   - scrolledBy: how far down from the top the content currently sits. Negative while
    ///     rubber-banding past the top, and larger than the real maximum while rubber-banding past the
    ///     bottom.
    static func showsMoreBelow(contentHeight: CGFloat, visibleHeight: CGFloat, scrolledBy: CGFloat) -> Bool {
        // L50: a measurement never reaches the comparison directly. SwiftUI lays out once before it has
        // measured anything, where every value is zero, and a NaN compares false against every threshold,
        // so an unguarded version lands on whichever side the operator happens to give. Unmeasured means
        // "nothing to say", never "everything is hidden": the other way round flashes a cue onto every
        // panel in the app for one frame, including the ones that fit.
        guard contentHeight.isFinite, visibleHeight.isFinite, scrolledBy.isFinite,
              contentHeight > 0, visibleHeight > 0
        else { return false }

        // Overscroll past the top reads as a negative offset and means MORE is below, not less.
        let travelled = max(0, scrolledBy)
        return contentHeight - visibleHeight - travelled > roundingTolerance
    }
}
