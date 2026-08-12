import SwiftUI

// #2546: the sentence shown beside a control that is refusing, in ONE place, because four surfaces now
// show one and four hand-rolled copies would drift in wording weight and in whether they appear at all.
//
// Nil renders nothing, deliberately: a line that is always on screen stops being read (#843), so this
// exists only while the control it explains is actually grey. It takes the reason rather than the
// predicate, so it cannot answer a different question from the `.disabled(...)` beside it.
//
// The accessibility identifier is what makes the on-screen tests honest, and it is load-bearing rather
// than decoration. `.help()` puts its string into the view hierarchy too, so a test that searched the
// tree for the sentence would pass with the visible line deleted and only the tooltip left. #2544 hit
// exactly that: its first on-screen tests passed with the visible line removed. Searching for this
// identifier can only ever match a line Dan can see.
struct ControlRefusalLine: View {
    static let identifier = "control-refusal"

    let reason: String?
    var alignment: TextAlignment = .leading

    var body: some View {
        if let reason {
            Text(reason)
                .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(alignment)
                .accessibilityIdentifier(Self.identifier)
        }
    }
}
