import Foundation

// #1574. Which search result the keyboard is sitting on, held outside the view so it can be tested
// (a SwiftUI body's own @State is unreachable from a test, per the same reason ShowSearch itself
// lives out here). The view owns the key events and the highlight; every decision about WHICH row
// is here.
//
// Dan's call on the starting state: nothing is highlighted until he presses an arrow, so Return is
// inert until he has actually moved onto a result and can see which one he is about to open. That
// is why `index` is optional rather than starting at 0.
//
// The ends clamp rather than wrap: holding the arrow down rests on the last result instead of
// silently jumping back to the top, where a second later Return would open a show he never looked at.
struct ShowSearchSelection: Equatable {
    private(set) var index: Int?

    mutating func moveDown(resultCount: Int) {
        guard resultCount > 0 else { index = nil; return }
        guard let current = index else { index = 0; return }
        index = min(current + 1, resultCount - 1)
    }

    // From nothing, up enters the list at the bottom, the way a macOS menu does.
    mutating func moveUp(resultCount: Int) {
        guard resultCount > 0 else { index = nil; return }
        guard let current = index else { index = resultCount - 1; return }
        index = max(current - 1, 0)
    }

    // The query changed (or the dropdown closed), so the old highlight means nothing.
    mutating func clear() {
        index = nil
    }

    // What Return should open, or nil for "do nothing". Never returns a position the result list no
    // longer has: the list is recomputed from the query on every keystroke and can shrink under a
    // highlight that was valid a moment ago, and a stale index handed back as a subscript would trap.
    func commitIndex(resultCount: Int) -> Int? {
        guard let index, index >= 0, index < resultCount else { return nil }
        return index
    }
}
