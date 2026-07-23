import SwiftUI

// #1409: shown once at launch, and only when Overture opened with far fewer shows than its most recent
// backup holds. A sheet rather than the bottom banner (Dan's call): the banner fades after a few
// seconds, so the one launch this ever fires on is one Dan could look away from and miss entirely, and
// every action taken afterwards makes restoring messier. It stops him at the moment restoring is
// easiest, and the cost of a false alarm is a single dismissal.
//
// Matches SelfBookingConfirmSheet's framing (dark green header, lighter body). It carries no copy of
// its own beyond its two labels: the sentence comes from StoreShrinkCheck, which is tested, so what a
// person reads here cannot drift under a green suite (#885).
struct StoreShrinkNoticeSheet: View {
    let finding: StoreShrinkCheck.Finding
    let backupsPath: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: OVSpacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 15))
                    .foregroundStyle(OVColor.goldBright)
                Text(finding.title)
                    .font(OVType.dateHeading)
                    .foregroundStyle(OVColor.onForest)
            }
            .padding(.horizontal, OVSpacing.lg)
            .padding(.vertical, OVSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OVColor.canvas)

            VStack(alignment: .leading, spacing: OVSpacing.md) {
                Text(finding.message)
                    .font(OVType.body)
                    .foregroundStyle(OVColor.onForest)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // The path, selectable, because the next thing Dan does with it is paste it somewhere.
                Text(backupsPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(OVColor.onForest.opacity(0.75))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Button(StoreShrinkCopy.reveal) {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: backupsPath)
                    }
                    Spacer()
                    Button(StoreShrinkCopy.dismiss) { onDismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(OVColor.rust)
                }
            }
            .padding(OVSpacing.lg)
        }
        .frame(width: 460)
        .background(OVColor.forest)
    }
}

// The sheet's own two labels and its heading, out of the view body so the copy inventory reads them and
// a test can pin them (#863/#885).
enum StoreShrinkCopy {
    static let reveal = "Show me the backups"
    // Not "OK": this dismisses a warning about possible data loss, and the button should say what
    // taking it means rather than sounding like agreement.
    static let dismiss = "Continue anyway"
}

// Attached at the window, so RootView neither knows nor cares. Its own State means the sheet closes for
// good once dismissed: this is a launch-time finding, not a condition to re-nag about all session.
struct StoreShrinkNotice: ViewModifier {
    let finding: StoreShrinkCheck.Finding?
    let backupsPath: String
    @State private var dismissed = false

    func body(content: Content) -> some View {
        content.sheet(isPresented: .init(get: { finding != nil && !dismissed },
                                         set: { if !$0 { dismissed = true } })) {
            if let finding {
                StoreShrinkNoticeSheet(finding: finding, backupsPath: backupsPath) { dismissed = true }
            }
        }
    }
}

extension View {
    func storeShrinkNotice(_ finding: StoreShrinkCheck.Finding?, backupsPath: String) -> some View {
        modifier(StoreShrinkNotice(finding: finding, backupsPath: backupsPath))
    }
}
