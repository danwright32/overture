import SwiftUI

// #1249: the self double-booking confirms (Approve, per-row Re-prep, and the batch Prep sheet) used plain
// system confirmationDialogs, off-brand next to Overture's own surfaces. This is their first-party
// replacement, matching SendConfirmSheet's forest header and framing. The proceed button is a CAUTIONARY
// rust (Dan, 2026-07-20): it proceeds PAST a double-booking warning, so it should read as a deliberate
// override, not a celebratory commit like the gold Send. It carries no copy of its own: the title, message
// and proceed label all come from SelfBookingCopy (already tested) and are passed in, so the words a person
// reads here can't drift under a green suite.
struct SelfBookingConfirmSheet: View {
    let title: String
    let message: String
    let proceedLabel: String
    // #1500: the sheet is now the app's one branded confirm for any deliberate, cautionary action, and a
    // calendar warning is the wrong picture over "dismiss the whole night as Not a fit". Defaulted, so
    // every existing caller keeps the icon it shipped with.
    var symbol: String = "calendar.badge.exclamationmark"
    let onProceed: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: OVSpacing.sm) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(OVColor.goldBright)
                Text(title)
                    .font(OVType.dateHeading)
                    .foregroundStyle(OVColor.onForest)
            }
            .padding(.horizontal, OVSpacing.lg)
            .padding(.vertical, OVSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OVColor.canvas)   // #1249: DARK green on top (Dan, 2026-07-20)

            VStack(alignment: .leading, spacing: OVSpacing.md) {
                Text(message)
                    .font(OVType.body)
                    .foregroundStyle(OVColor.onForest)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Button(SendConfirmCopy.cancel) { onCancel() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button { onProceed() } label: {
                        Text(proceedLabel)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(OVColor.rust)
                }
            }
            .padding(OVSpacing.lg)
        }
        .frame(width: 420)
        .background(OVColor.forest)   // #1249: lighter green on the bottom (Dan, 2026-07-20)
    }
}
