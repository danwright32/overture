import SwiftUI

// #1175: the small tinted capsule button used for inline row actions (Fix / Confirm / Save / Cancel /
// Add address). Extracted so the Sources sheet's venue-location control and SourceFixConfirmActions share
// ONE implementation rather than each keeping its own copy of the same styling.
struct OVCapsuleButton: View {
    let label: String
    var tint: Color = OVColor.forestText
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .foregroundStyle(tint)
                .ovCapsuleAction()
        }
        .buttonStyle(.plain)
    }
}

extension View {
    // #1460: the shared secondary-action capsule chrome (font, padding, bordered capsule) that says "you
    // can do this". Worn by BOTH OVCapsuleButton and the queue's Dismiss control, which is a Menu (it opens
    // a reason list) rather than a Button, so a struct wrapper could not cover both: a modifier can. Before
    // this the two matched only by eye and had drifted (the Dismiss menu was semibold and md/6, chunkier
    // than this; #1460 standardised on these, the OVCapsuleButton metrics). Foreground stays at the call
    // site: the TINT varies (forest for a positive action, inkSoft for a neutral one), the shape must not.
    func ovCapsuleAction() -> some View {
        self
            .font(.system(size: 11))
            .padding(.horizontal, OVSpacing.sm)
            .padding(.vertical, 4)
            .background(Capsule().strokeBorder(OVColor.lineStrong, lineWidth: 1))
    }
}
