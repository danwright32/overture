import SwiftUI

// #4108: an OPAQUE cover over the presenting content while a branded confirm is up.
//
// WHAT WAS MEASURED. On 2026-09-21 Dan dismissed a whole night and screenshotted the "Dismiss all 7
// shows on Oct 4?" sheet sitting over a window that had not finished redrawing: card text and
// oversized heading text from the queue behind were drawn on top of each other, all round the sheet.
// The freeze log beside it recorded 1.38s and 1.88s stalls, both with `passes=0`, so the app went
// silent without completing a single render pass and the partly composed frame stayed on screen.
//
// IT IS A FREEZE, NOT A STYLING FAULT, and this does not pretend to fix the freeze. `SelfBookingConfirmSheet`
// already sets both its own backgrounds, so nothing shows THROUGH the sheet; what Dan saw was the
// window AROUND it. #4106 is the rebuild that makes the window slow. This is the separate, cheaper
// guarantee that the one surface where reading the screen matters most is legible whatever the window
// behind it is doing: the button buries seven shows, and a confirmation should not be legible only by
// luck.
//
// OPAQUE rather than dimmed, and that is the whole point. A scrim at any partial opacity still lets a
// half-drawn frame through, fainter; the defect is that the text underneath is unreadable rubbish, and
// rubbish at 40% is still rubbish. `ConfirmBackdropRendersTests` measures it as a pixel count rather
// than asserting a modifier is present, because "there is a cover" and "nothing shows through it" are
// different claims and only the second is the requirement (L63).
//
// WHY A VIEW AND NOT A MODIFIER inline in the host: so it can be rendered on its own in a test over a
// deliberately loud background. A cover that is only ever composed into the real host can only be
// tested by asserting the call site says the right words, which is a guard that cannot fail (L1).
struct ConfirmBackdrop: View {
    var body: some View {
        // `OVColor.canvas` is the app's own ground, so the sheet sits on Overture's dark green rather
        // than on a system material that would read as the OS pasted into the product (L607).
        OVColor.canvas
            .ignoresSafeArea()
            // It carries no information and must never be announced or focusable: what a screen reader
            // should find while a confirm is up is the confirm (L577).
            .accessibilityHidden(true)
    }
}
