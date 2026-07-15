import SwiftUI

// #360: the words Dan reads at the single most consequential moment (a real email leaving) live
// here in one place, not computed inside the view, so a wording rule can't silently drift under a
// green suite (a lesson from earlier view-embedded logic). SendConfirmSheetTests locks these.
enum SendConfirmCopy {
    static let title = "Send this email now?"
    static let reassurance = "This sends one email right now, to this recipient only. Nothing else goes out."
    static let fromLabel = "From"
    static let toLabel = "To"
    static let subjectLabel = "Subject"
    static let previewLabel = "The email that will send"
    static let send = "Send"
    static let cancel = "Cancel"
    // #361: the gold seal on a just-sent row as it leaves the queue.
    static let sentSeal = "Sent"
}

// #360: a first-class, on-brand replacement for the old stock system send-confirm alert. Shows the
// exact From / To / Subject and a scrollable preview of the body about to go out, then the "one
// email, nothing else" reassurance, and a deliberate gold Send that reads as the primary commit.
struct SendConfirmSheet: View {
    let confirmation: SendConfirmation
    let onSend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: OVSpacing.sm) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(OVColor.goldBright)
                Text(SendConfirmCopy.title)
                    .font(OVType.dateHeading)
                    .foregroundStyle(OVColor.onForest)
            }
            .padding(.horizontal, OVSpacing.lg)
            .padding(.vertical, OVSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OVColor.forest)

            VStack(alignment: .leading, spacing: OVSpacing.md) {
                VStack(spacing: 0) {
                    field(SendConfirmCopy.fromLabel, confirmation.from.display)
                    Divider().overlay(OVColor.line)
                    field(SendConfirmCopy.toLabel, confirmation.recipient)
                    Divider().overlay(OVColor.line)
                    field(SendConfirmCopy.subjectLabel, confirmation.subject, emphasised: true)
                }

                VStack(alignment: .leading, spacing: OVSpacing.xs) {
                    Text(SendConfirmCopy.previewLabel)
                        .font(OVType.meta)
                        .foregroundStyle(OVColor.inkFaint)
                        .textCase(.uppercase)
                    ScrollView {
                        Text(confirmation.body)
                            .font(OVType.body)
                            .foregroundStyle(OVColor.inkSoft)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                    .padding(OVSpacing.sm)
                    .background(OVColor.surfaceSunk)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(OVColor.line))
                }

                HStack(alignment: .top, spacing: OVSpacing.xs) {
                    Circle().fill(OVColor.gold).frame(width: 6, height: 6).padding(.top, 5)
                    Text(SendConfirmCopy.reassurance)
                        .font(.system(size: 12))
                        .foregroundStyle(OVColor.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button(SendConfirmCopy.cancel) { onCancel() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button { onSend() } label: {
                        Label(SendConfirmCopy.send, systemImage: "paperplane")
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(OVColor.gold)
                }
            }
            .padding(OVSpacing.lg)
        }
        .frame(width: 460)
        .background(OVColor.canvas)
    }

    private func field(_ label: String, _ value: String, emphasised: Bool = false) -> some View {
        HStack(alignment: .top, spacing: OVSpacing.sm) {
            Text(label)
                .font(OVType.meta)
                .foregroundStyle(OVColor.inkFaint)
                .textCase(.uppercase)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(emphasised ? OVType.body.weight(.medium) : OVType.body)
                .foregroundStyle(OVColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, OVSpacing.xs)
    }
}
