import SwiftUI

// #2188: shown when an update Dan asked for did not happen.
//
// Pressing Update opens a Terminal window and the app used to forget it entirely, so a refusal and a
// success looked the same from inside Overture: nothing. On 2026-08-06 the run refused (another session
// had work in progress in the checkout), printed its reason into that window, and the app went quiet for
// the rest of the launch about a copy that was still out of date. Dan read the whole thing as "it said
// nothing to update".
//
// Same framing as BuildFreshnessSheet, which is the panel this one follows: it appears in the same place,
// for the same press, and reading them as one surface is the point. It carries no sentence of its own,
// so what he reads here is either the run's own words or a sentence that lives in UpdateAttemptCopy and
// is tested.
struct UpdateFailureSheet: View {
    let progress: UpdateAttempt.Progress
    // Whether there is anywhere to run the update from. False means no record of the checkout, and then
    // no button, because a button that cannot act reads as an update that ran and did nothing (#1778).
    let canRetry: Bool
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: OVSpacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 15))
                    .foregroundStyle(OVColor.goldBright)
                Text(UpdateAttemptCopy.title)
                    .font(OVType.dateHeading)
                    .foregroundStyle(OVColor.onForest)
            }
            .padding(.horizontal, OVSpacing.lg)
            .padding(.vertical, OVSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OVColor.canvas)

            VStack(alignment: .leading, spacing: OVSpacing.md) {
                Text(UpdateAttemptCopy.body(progress))
                    .font(OVType.body)
                    .foregroundStyle(OVColor.onForest)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Button(UpdateAttemptCopy.dismiss) { onDismiss() }
                        .buttonStyle(.plain)
                        .foregroundStyle(OVColor.onForest.opacity(0.75))
                    Spacer()
                    if canRetry {
                        // The reason is usually something that clears in a minute, so the way back to
                        // the update is here rather than leaving him to find the panel again.
                        Button(UpdateAttemptCopy.tryAgain) { onRetry() }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                            .tint(OVColor.gold)
                    }
                }
            }
            .padding(OVSpacing.lg)
        }
        .frame(width: 620)
        .background(OVColor.forest)
    }
}
