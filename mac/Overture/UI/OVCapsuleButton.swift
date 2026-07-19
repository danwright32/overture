import SwiftUI

// #1175: the small tinted capsule button used for inline row actions (Fix / Confirm / Save / Cancel /
// Add address). Extracted so the Sources sheet's venue-location control and SourceFixConfirmActions share
// ONE implementation rather than each keeping its own copy of the same styling.
struct OVCapsuleButton: View {
    let label: String
    var tint: Color = OVColor.forest
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .padding(.horizontal, OVSpacing.sm)
                .padding(.vertical, 4)
                .background(Capsule().strokeBorder(OVColor.lineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
