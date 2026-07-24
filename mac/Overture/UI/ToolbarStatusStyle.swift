import SwiftUI

// #1411: the inset the toolbar's status slot gives its own content, because macOS gives it none.
//
// That slot is the one place in the toolbar that hands the system a BARE view: a Text for the scout's
// quiet warning, a Label for the OmniFocus failure. Every other item is a Button or a Menu, and those
// bring control insets of their own, which is why only this one shrink-wrapped its glyphs and put the
// sentence hard against the edge of the rounded box macOS draws around it. Dan: "no text should ever come
// that close to the edge of the box."
//
// The numbers live here rather than at the two call sites so a test can pin them (#863) and so the two
// branches cannot drift into being padded differently. They are the app's ordinary pill inset
// (OVCapsuleButton), not new values: this slot should look like the rest of the app, and #1411's
// suggested "12 by 5" would have made the toolbar the only place using a fifth spacing number.
enum ToolbarStatusStyle {
    static let horizontalInset: CGFloat = OVSpacing.sm
    static let verticalInset: CGFloat = OVSpacing.xxs
}

extension View {
    // Pad and GROW (Dan's call on #1411): the capsule sizes to whatever it wraps, so the whole sentence
    // stays readable. Deliberately no lineLimit or truncation, because this slot is where the scout says
    // the one thing Dan can act on, and a clipped warning is worse than a cramped one.
    func toolbarStatusInset() -> some View {
        padding(.horizontal, ToolbarStatusStyle.horizontalInset)
            .padding(.vertical, ToolbarStatusStyle.verticalInset)
    }
}
