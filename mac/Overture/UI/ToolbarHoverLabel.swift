import SwiftUI

// #337 / #901: a toolbar button's icon with its name always beside it.
//
// It began (#337) as a hover-to-expand pill, because macOS collapses a plain toolbar Label's text by
// default at this size and the names were easy to miss. But animating each button's WIDTH to reveal its
// label made the toolbar misbehave: macOS does not reflow the neighbouring items in step with the
// animation, so mid-expand the buttons drew on top of each other and the icon spilled out of its
// container. Dan hit every version of that (jumpy, too fast, then overlapping) walking the app on
// 2026-07-14, and chose the fix that removes the entire failure class: the label is simply always shown.
// Nothing widens on hover, so nothing can overlap. The toolbar is wider, which the layout has room for.
struct ToolbarHoverLabel: View {
    let title: String
    let systemImage: String
    // Retained so the nine call sites don't all have to change. It used to force the label to stay up for
    // a button reporting a count/state; now every label stays up, so it no longer does anything. The gold
    // attention tint those callers apply lives at the call site, not here, and still works.
    var showsTitle: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(title).fixedSize()
        }
    }
}
