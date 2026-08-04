import SwiftUI
import AppKit

// #1808: shown at launch when the installed copy is behind what has shipped, or when Overture cannot
// tell how old it is.
//
// Dan chose the shape, 2026-08-03: "a pop up window that takes up most of the app screen. It can be
// dismissed." A quiet masthead line was the alternative and he turned it down, for the right reason:
// the whole failure is that he does not notice the gap, and a line he can miss is a line he will miss.
// He has reported bugs in behaviour that was already fixed because the fix was not in front of him.
//
// Follows StoreShrinkNoticeSheet's framing (#1409), which is the other launch-time notice: same header,
// same body treatment, wider because this one is meant to be unmissable. It carries no sentence of its
// own: every word comes from BuildFreshnessCopy, which is tested, so what Dan reads here cannot drift
// under a green suite (#885).
struct BuildFreshnessSheet: View {
    let verdict: BuildFreshness.Verdict
    // Where the installer built from, or nil when there is no record of an install. Nil means no Update
    // button, because a button that cannot act reads as an update that ran and did nothing (#1778).
    let repoPath: String?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: OVSpacing.sm) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(OVColor.goldBright)
                Text(BuildFreshnessCopy.title(verdict))
                    .font(OVType.dateHeading)
                    .foregroundStyle(OVColor.onForest)
            }
            .padding(.horizontal, OVSpacing.lg)
            .padding(.vertical, OVSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OVColor.canvas)

            VStack(alignment: .leading, spacing: OVSpacing.md) {
                Text(BuildFreshnessCopy.body(verdict))
                    .font(OVType.body)
                    .foregroundStyle(OVColor.onForest)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if repoPath != nil {
                    // Said BEFORE he presses it: the installer quits Overture partway through and
                    // relaunches it, so the app vanishing mid-update is the update working rather than a
                    // crash. Without this line the button looks like it killed the app.
                    Text(BuildFreshnessCopy.updateNote)
                        .font(OVType.meta)
                        .foregroundStyle(OVColor.onForest.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(BuildFreshnessCopy.cannotUpdate)
                        .font(OVType.meta)
                        .foregroundStyle(OVColor.onForest.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Button(BuildFreshnessCopy.dismiss) { onDismiss() }
                        .buttonStyle(.plain)
                        .foregroundStyle(OVColor.onForest.opacity(0.75))
                    Spacer()
                    if let repoPath {
                        Button(BuildFreshnessCopy.update) {
                            // Dismissed first: the installer quits this process moments later, and a
                            // sheet still up when the window goes is a worse last frame than a closed one.
                            onDismiss()
                            UpdateCommandFile.open(repoPath: repoPath)
                        }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(OVColor.gold)
                    }
                }
            }
            .padding(OVSpacing.lg)
        }
        // Wider than the other notices on purpose: Dan asked for something taking up most of the window,
        // because this is the one notice whose whole job is to be impossible to work past without seeing.
        .frame(width: 620)
        .background(OVColor.forest)
    }
}

// Attached at the window, like StoreShrinkNotice, so RootView neither knows nor cares. Its own State
// holds the dismissal for THIS LAUNCH only: BuildFreshnessPanel.shouldShow owns that rule, and a
// dismissal that outlived the launch would quietly recreate the gap this exists to close.
struct BuildFreshnessNotice: ViewModifier {
    let verdict: BuildFreshness.Verdict
    let repoPath: String?
    @State private var dismissed = false

    func body(content: Content) -> some View {
        content.sheet(isPresented: .init(
            get: { BuildFreshnessPanel.shouldShow(verdict, dismissedThisLaunch: dismissed) },
            set: { if !$0 { dismissed = true } })) {
            BuildFreshnessSheet(verdict: verdict, repoPath: repoPath) { dismissed = true }
        }
    }
}

extension View {
    func buildFreshnessNotice(_ verdict: BuildFreshness.Verdict, repoPath: String?) -> some View {
        modifier(BuildFreshnessNotice(verdict: verdict, repoPath: repoPath))
    }
}
