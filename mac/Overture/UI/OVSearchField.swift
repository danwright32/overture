import SwiftUI

// #1432: the search control itself, in one place.
//
// Two surfaces search now and they are different INTERACTIONS: the toolbar's ShowSearchField jumps to a
// show through a results popover, while the Sources sheet filters the list under it in place. What they
// share is the control Dan looks at and types into, and that had been built twice, down to the same icon,
// the same conditional clear button and the same sunk background. A second copy of a control drifts, and
// two search fields that look subtly unalike teach Dan that they work unalike.
//
// So the CHROME is shared here and the behavior stays with each caller. It holds no copy of its own:
// every string is handed in by the surface that owns it, which keeps the app's words in the tested
// domain types rather than in a view (#885).
struct OVSearchField: View {
    @Binding var query: String
    let placeholder: String
    // Optional because the clear button is an icon with no text, so it needs a spoken name wherever it
    // is offered. Left nil by a caller that has none to give rather than inventing one here.
    var clearLabel: String?
    // Handed in by a caller that drives something off focus (the toolbar field opens its results popover
    // on it). Absent for a field that just filters what is already on screen.
    var focused: FocusState<Bool>.Binding?

    var body: some View {
        HStack(spacing: OVSpacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(OVColor.inkFaint)

            field

            // Only once there is something to clear, so the field is not permanently wearing a control
            // that would do nothing.
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(OVColor.inkFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(clearLabel ?? "")
            }
        }
        .padding(.horizontal, OVSpacing.sm).padding(.vertical, 6)
        .background(Capsule().fill(OVColor.surfaceSunk))
        .overlay(Capsule().strokeBorder(OVColor.line, lineWidth: 1))
    }

    @ViewBuilder private var field: some View {
        // #2217. The empty action is the behaviour, not a placeholder. A text field with NO submit
        // handler lets Return through to whatever the host window has made its default button. On the
        // Sources sheet that is Done, so the reflex of pressing Return after typing a search term
        // dismissed the sheet and took the search, the scroll position and any inline edit in progress
        // with it. Registering a handler makes the field consume the keypress, and there is genuinely
        // nothing for it to DO: both surfaces search live as you type, so the results are already on
        // screen by the time Return is pressed.
        //
        // It lives here rather than in either sheet so the next surface to host this field inherits
        // the fix instead of the bug.
        let base = TextField(placeholder, text: $query)
            .textFieldStyle(.plain)
            .onSubmit { }
        if let focused {
            base.focused(focused)
        } else {
            base
        }
    }
}
