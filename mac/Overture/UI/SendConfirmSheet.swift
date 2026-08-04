import SwiftUI

// #360: the words Dan reads at the single most consequential moment (a real email leaving) live
// here in one place, not computed inside the view, so a wording rule can't silently drift under a
// green suite (a lesson from earlier view-embedded logic). SendConfirmSheetTests locks these.
enum SendConfirmCopy {
    static let title = "Send this email now?"
    // #1219: the self double-booking warning shown in the send sheet is now dynamic (it names the clashing
    // show), so it lives in SelfBookingCopy.confirmWarning, set on SendConfirmation.selfBookingWarning.
    static let reassurance = "This sends one email right now, to this recipient only. Nothing else goes out."
    // #2033: the same promise for an email several people are on. It names the number rather than saying
    // "these recipients", because the count is the thing he is checking when he reads the To line above it.
    static func reassuranceForSeveral(_ count: Int) -> String {
        let who = count == 2 ? "both of these people" : "all \(count) of these people"
        return "This sends one email right now, to \(who). Nothing else goes out."
    }
    // #948: the follow-up and conversation-note sends share this sheet. Their heading and reassurance
    // differ from the draft's (and a closing note names the second thing it does), and they live here
    // beside the draft's so all three are read together, in one place, rather than in three view bodies.
    static let followUpTitle = "Send this follow-up now?"
    static let followUpReassurance = "This sends one follow-up right now, to this recipient only. Nothing else goes out."
    static let noteTitle = "Send this note now?"
    static let noteReassurance = "This sends one message right now, to this recipient only."
    static let noteReassuranceClosing = "This sends one message right now, to this recipient only. It also closes the lead out (kept warm for next time)."
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
                Text(confirmation.title)
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

                // #1219: a self double-booking warning, shown at the committing moment so Dan confirms
                // past it deliberately rather than forgetting he already pitched this date.
                if let warning = confirmation.selfBookingWarning {
                    HStack(alignment: .top, spacing: OVSpacing.xs) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(OVColor.rust)
                            .padding(.top, 1)
                        Text(warning)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(OVColor.rust)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(alignment: .top, spacing: OVSpacing.xs) {
                    Circle().fill(OVColor.gold).frame(width: 6, height: 6).padding(.top, 5)
                    Text(confirmation.reassurance)
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

// #2033: the tag on a contact row saying this email is going to them. Out of the view because a view that
// computes its own wording drifts under a green suite (ViewCopyGuardTests).
enum DraftContactCopy {
    static func nextSendTag(recipients: Int) -> String {
        recipients > 1 ? "On this email" : "Sending to this one"
    }
}
