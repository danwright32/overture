import SwiftUI

// Shown instead of the queue when Overture can't open its data (#264 / Phase 0): another copy holds
// the single-writer lock, or the store failed to open. This REPLACES the old fatalError: under the
// future launchd agent a crash would become a respawn loop on a transiently locked store.
struct StoreUnavailableView: View {
    let reason: String

    var body: some View {
        VStack(spacing: OVSpacing.md) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(OVColor.inkSoft)
            Text("Overture's data is unavailable")
                .font(OVType.dateHeading).foregroundStyle(OVColor.ink)
            Text(reason)
                .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("If another Overture window is open, use that one. Otherwise quit and reopen Overture.")
                .font(OVType.meta).foregroundStyle(OVColor.inkFaint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(OVSpacing.xl)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OVColor.canvas)
    }
}
