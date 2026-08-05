import SwiftUI
import SwiftData

// #2128: answering a reply from the Reached out queue. Dan (2026-08-05): "The reply itself should be
// done in the reached out queue. I'm never going to archive unless I need to look at something in the
// past. archive is only for things that are done and that I can't pitch/respond to anymore."
//
// A panel over the queue rather than the row growing in place. QueueView's body derives the whole store
// (`makeRenderData`), and `@State` invalidates the view that DECLARES it, so a compose box owning its
// text on that view would re-derive every prospect on every keystroke, which is the defect #1774, #1922
// and #1923 each fought. The typing lives in here, one level down, where it costs one panel.
//
// Mirrors InquiryReplySheet, which already answers an inquiry this way: hand-typed by default, with
// working, still-alive and failed as three visibly different states. One list should not behave two ways.
struct ReplyPanelSheet: View {
    let prospect: Prospect
    // The peer who actually WROTE, resolved by the caller through ReplyIdentity.answering. The row the
    // list stands on is picked by sorted id and is routinely somebody else.
    let recipient: Recipient
    let gmailConnected: Bool
    var sender: MailSender = ProspectMutations.liveSender()

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ActionFeedback.self) private var feedback

    @State private var body_ = ""
    @State private var phase: Phase = .compose

    private enum Phase: Equatable { case compose, sending, failed(String) }

    private var audience: [String] { SendGroup.replyAudience(of: recipient) }
    private var canSend: Bool {
        ReplyPanel.canSend(body: body_, audience: audience, gmailConnected: gmailConnected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            header
            theirReply
            switch phase {
            case .compose, .sending:
                compose
            case .failed(let message):
                Text(message).font(OVType.body).foregroundStyle(OVColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(OVSpacing.lg)
        .frame(width: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(prospect.groupName).font(.system(size: 15, weight: .semibold)).foregroundStyle(OVColor.ink)
            // L64: the audience is stated before the button, because a reply mirrors the addressing of the
            // message it answers and that is routinely not who the original email went to.
            Text(ReplyPanel.audienceLine(audience))
                .font(OVType.meta).foregroundStyle(audience.isEmpty ? OVColor.rust : OVColor.inkSoft)
        }
    }

    @ViewBuilder private var theirReply: some View {
        if let words = ReplyPanel.theirWords(recipient) {
            ScrollView {
                Text(words).font(OVType.body).foregroundStyle(OVColor.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 160)
            .padding(OVSpacing.sm)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(OVColor.surfaceSunk.opacity(0.6)))
        } else {
            Text(ReplyPanelCopy.noCapturedWords).font(OVType.meta).foregroundStyle(OVColor.inkFaint)
        }
    }

    // Empty and ready to type: Dan writes these himself. "I'll respond to whatever it is they say, usually
    // by hand without needing AI to write it, although I should be given the option to trigger an AI
    // written draft if i choose too (that's not the default in that situation though)."
    private var compose: some View {
        TextEditor(text: $body_)
            .font(OVType.body)
            .frame(minHeight: 160)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(OVColor.line))
            .disabled(phase == .sending)
    }

    private var footer: some View {
        HStack(spacing: OVSpacing.sm) {
            Button(ReplyPanelCopy.cancel) { dismiss() }
                .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            // #2129: offered, never automatic. Dan writes these himself and presses this only if he wants
            // to. Scoped to THIS reply, so it spends on the one conversation he asked about.
            if phase != .sending {
                Button(ReplyPanelCopy.draftWithAI) {
                    ProspectMutations.draftOneReply(prospect.naturalKey, recipient.id,
                                                    prospects: [prospect], context: context, feedback: feedback)
                    dismiss()
                }
                .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.forest)
                .help(ReplyPanelCopy.draftWithAIHelp)
            }
            Spacer()
            if phase == .sending {
                LiveRunLabel(base: ReplyPanelCopy.sending, since: Date(), timeout: RunTimeouts.send,
                             font: OVType.meta, color: OVColor.inkSoft)
            } else {
                Button(ReplyPanelCopy.send) { send() }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                    .disabled(!canSend)
                    .help(GmailCopy.sendHelp(connected: gmailConnected,
                                             whenConnected: ReplyPanelCopy.sendHelp))
            }
        }
    }

    private func send() {
        phase = .sending
        Task {
            await GmailSignatureService.refreshBeforeSend()
            // The sequence itself lives in ReplyPanel.commit, where a test can reach it.
            let sent = await ReplyPanel.commit(body: body_, on: recipient, of: prospect,
                                               now: Date(), sender: sender)
            context.saveOrWarnSendNotConfirmed(org: prospect.groupName, feedback: feedback)
            if sent {
                dismiss()
            } else {
                // A failure becomes an actionable state with the send button back, never a dead spinner
                // and never a silent fake success (CLAUDE.md, L12).
                phase = .failed(ReplyPanelCopy.sendFailed)
            }
        }
    }
}

// What the panel is about: the show and the peer who wrote. A struct rather than the two ids, so the
// sheet never has to look anything up and cannot land on a different row than the one Dan pressed.
struct ReplyTarget: Identifiable {
    let prospect: Prospect
    let recipient: Recipient
    var id: String { prospect.naturalKey + "|" + recipient.id }
}

// #2130: the nudge or closing note the reached-out row is about to send, held while Dan approves it.
struct PendingRowNudge: Identifiable {
    let naturalKey: String
    let recipientId: String
    let confirmation: SendConfirmation
    let isClosing: Bool
    // Which sender it goes through. The two write different emails, so the confirmation Dan reads and the
    // send that follows have to agree about which one this is.
    let isConversation: Bool
    var id: String { naturalKey + "|" + recipientId }
}
