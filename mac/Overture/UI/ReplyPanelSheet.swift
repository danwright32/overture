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
    var sender: MailSender

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ActionFeedback.self) private var feedback

    @State private var body_: String
    // #2143: what the box was last given, so a draft landing later can tell text Dan has since written
    // from text he was handed and has not touched.
    @State private var seeded: String
    // #2143: a draft that arrived while he was writing. Held, not applied: replacing words somebody is
    // in the middle of typing is the one thing reading the screen afterwards cannot undo.
    @State private var offeredDraft: String?
    @State private var phase: Phase = .compose
    // #2144: what Dan is about to approve, held while he reads it. Nil until Send is pressed, which is
    // deliberate: building it composes the signature onto the body, and hanging that off every keystroke
    // would pay the whole composition per character (L59, L62).
    @State private var pending: PendingReply?

    private enum Phase: Equatable { case compose, sending, failed(String) }

    // #2143: the box opens on the draft already waiting on this contact. Seeded at construction rather
    // than in an onAppear, so the panel is never on screen holding an empty box over a draft that exists,
    // not even for one frame.
    init(prospect: Prospect, recipient: Recipient, gmailConnected: Bool,
         sender: MailSender = ProspectMutations.liveSender()) {
        self.prospect = prospect
        self.recipient = recipient
        self.gmailConnected = gmailConnected
        self.sender = sender
        let opening = ReplyPanel.openingBody(recipient)
        _body_ = State(initialValue: opening)
        _seeded = State(initialValue: opening)
    }

    private var audience: [String] { SendGroup.replyAudience(of: recipient) }
    // #2152: one decision, asked once. The button's disabled state and the reason on screen come from the
    // same value, so a refusal can never be enforced without being stated.
    private var refusal: ReplyPanel.SendRefusal? {
        ReplyPanel.refusal(body: body_, audience: audience, gmailConnected: gmailConnected,
                           writer: recipient.replyFromAddress)
    }
    private var canSend: Bool { refusal == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            header
            theirReply
            switch phase {
            case .compose, .sending:
                draftOffer
                compose
            case .failed(let message):
                Text(message).font(OVType.body).foregroundStyle(OVColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(OVSpacing.lg)
        .frame(width: 560)
        // #2143: the drafter is detached, so its result lands on the contact while this panel is open.
        // Reading it here is what makes "Draft with AI" finish somewhere Dan is looking.
        .onChange(of: recipient.replyDraftBody) { _, arrived in
            let arrival = ReplyPanel.arriving(draft: arrived, typed: body_, seeded: seeded)
            apply(ReplyPanel.applying(arrival, to: composeState))
        }
        // #2144: the same sheet every other consequential send goes through, so a reply is approved with
        // its From, To, Subject and the composed message including the signature, on either background.
        .sheet(item: $pending) { held in
            SendConfirmSheet(confirmation: held.confirmation,
                             onSend: { pending = nil; send() },
                             onCancel: { pending = nil })
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xxs) {
            Text(prospect.groupName).font(.system(size: 15, weight: .semibold)).foregroundStyle(OVColor.ink)
            // L64: the audience is stated before the button, because a reply mirrors the addressing of the
            // message it answers and that is routinely not who the original email went to.
            //
            // #2155: one row per address rather than one sentence, so the panel can mark which of them
            // actually wrote and put a remove control on each.
            if audience.isEmpty {
                Text(ReplyPanelCopy.noAddress).font(OVType.meta).foregroundStyle(OVColor.rust)
            } else {
                Text(ReplyPanelCopy.audienceHeading).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                ForEach(ReplyPanel.audienceEntries(audience, writer: recipient.replyFromAddress)) { entry in
                    audienceRow(entry)
                }
                // #2151: the address that wrote is on none of this show's contacts, so say so and offer to
                // save it. Offered rather than done, because whether it is the same person from a second
                // mailbox or a colleague answering for them is a judgement only Dan can make.
                if let stranger = ReplyPanel.unknownWriter(on: recipient, of: prospect) {
                    unknownWriterOffer(stranger)
                }
            }
        }
    }

    private func unknownWriterOffer(_ address: String) -> some View {
        HStack(spacing: OVSpacing.xs) {
            Text(ReplyPanelCopy.writerNotAContact(address))
                .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Button(ReplyPanelCopy.saveWriter) { saveWriter() }
                .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.forest)
                .help(ReplyPanelCopy.saveWriterHelp)
            Spacer()
        }
        .padding(.top, OVSpacing.xxs)
    }

    private func saveWriter() {
        guard let address = ReplyPanel.unknownWriter(on: recipient, of: prospect) else { return }
        guard ReplyPanel.saveWriterAsContact(on: recipient, of: prospect) else { return }
        guard context.saveOrWarn(org: prospect.groupName, feedback: feedback) else { return }
        feedback.acknowledge(ReplyPanelCopy.savedWriter(address))
    }

    private func audienceRow(_ entry: ReplyPanel.AudienceEntry) -> some View {
        HStack(spacing: OVSpacing.xs) {
            Text(entry.address).font(OVType.meta).foregroundStyle(OVColor.ink)
            if entry.wrote {
                Text(ReplyPanelCopy.wroteThis).font(OVType.meta).foregroundStyle(OVColor.forest)
            }
            if entry.canRemove {
                // Icon only, so it carries the full sentence as its accessibility label as well as its
                // tooltip: the label is the only place the second half of what it does is stated.
                Button { remove(entry.address) } label: {
                    Image(systemName: "xmark.circle.fill").font(OVType.meta)
                }
                .buttonStyle(.plain)
                .foregroundStyle(OVColor.inkFaint)
                .help(ReplyPanelCopy.removeFromReply(entry.address))
                .accessibilityLabel(ReplyPanelCopy.removeFromReply(entry.address))
            }
            Spacer()
        }
    }

    private func remove(_ address: String) {
        let removal = ReplyPanel.removeFromReply(address, on: recipient, of: prospect)
        guard let said = ReplyPanelCopy.removed(removal, address: address) else { return }
        // Announced only once the write COMMITS, so the banner is never shown over a removal that did not
        // persist (L12). saveOrWarn puts its own warning up on the failure path.
        guard context.saveOrWarn(org: prospect.groupName, feedback: feedback) else { return }
        feedback.acknowledge(said)
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
        } else if let reason = ReplyPanel.missingWordsReason(recipient) {
            // #2149: which of the two reasons, decided beside the data rather than assumed here.
            Text(reason).font(OVType.meta).foregroundStyle(OVColor.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // #2143: the three pieces of the compose box as one value, so the rules about what may replace what
    // live in ReplyPanel where they are tested, and this view only reads and assigns.
    private var composeState: ReplyPanel.ComposeState {
        ReplyPanel.ComposeState(typed: body_, seeded: seeded, offered: offeredDraft)
    }

    private func apply(_ state: ReplyPanel.ComposeState) {
        body_ = state.typed
        seeded = state.seeded
        offeredDraft = state.offered
    }

    // #2143: the draft that came back while he was writing, offered above the box it would replace.
    @ViewBuilder private var draftOffer: some View {
        if offeredDraft != nil {
            HStack(spacing: OVSpacing.xs) {
                Text(ReplyPanelCopy.draftArrivedWhileWriting)
                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Button(ReplyPanelCopy.useTheDraft) { apply(ReplyPanel.taking(composeState)) }
                .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.forest)
                .help(ReplyPanelCopy.useTheDraftHelp)
                Spacer()
            }
        }
    }

    // Opens on the draft already waiting, and otherwise empty and ready to type: Dan writes these himself.
    // "I'll respond to whatever it is they say, usually
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
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            // #2152: why the Send button is refusing, above the button itself, so a refusal reads as a
            // refusal rather than as a broken control. The wording is ReplyPanelCopy's, never composed
            // here (ViewCopyGuardTests).
            if let reason = ReplyPanelCopy.refusalLine(refusal) {
                Text(reason).font(OVType.meta).foregroundStyle(OVColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            buttons
        }
    }

    private var buttons: some View {
        HStack(spacing: OVSpacing.sm) {
            Button(ReplyPanelCopy.cancel) { dismiss() }
                .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            // #2143: the run stays on the panel that started it. Pressing the button used to dismiss the
            // sheet, which put the only trace of a paid run that was under way (and of the draft it came
            // back with) on the Archive card Dan does not open, so working, still-alive and stalled were
            // all the same silence. Read from the contact rather than from a flag of this view's own, so
            // opening the panel onto a run already under way shows it too (L14).
            if ReplyPanel.isDrafting(recipient) {
                LiveRunLabel(base: ReplyPanelCopy.drafting, since: recipient.replyDraftRequestedAt,
                             timeout: RunTimeouts.replyDraft, font: OVType.meta, color: OVColor.inkSoft,
                             onRetry: { requestDraft() },
                             heartbeat: { ReplyClassifyService.heartbeat(now: Date()) })
            // #2129: offered, never automatic. Dan writes these himself and presses this only if he wants
            // to. Scoped to THIS reply, so it spends on the one conversation he asked about.
            } else if phase != .sending {
                Button(ReplyPanelCopy.draftWithAI) { requestDraft() }
                .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.forest)
                .help(ReplyPanelCopy.draftWithAIHelp)
            }
            Spacer()
            if phase == .sending {
                LiveRunLabel(base: ReplyPanelCopy.sending, since: Date(), timeout: RunTimeouts.send,
                             font: OVType.meta, color: OVColor.inkSoft)
            } else {
                Button(ReplyPanelCopy.send) { review() }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                    .disabled(!canSend)
                    // Says what the button DOES. Why it will not do it is stated on screen above rather
                    // than swapped in here, where only a hover would ever find it (#2152, L49).
                    .help(ReplyPanelCopy.sendHelp)
            }
        }
    }

    // #2143: asking for the draft, from the button and from the retry the stalled label offers, so the two
    // routes cannot start different runs.
    private func requestDraft() {
        ProspectMutations.draftOneReply(prospect.naturalKey, recipient.id,
                                        prospects: [prospect], context: context, feedback: feedback)
    }

    // #2144: step one of sending, and the only thing the Send button does now. Refreshes the signature
    // FIRST so the message Dan reads carries the signature the send will actually compose, then puts the
    // whole composed email in front of him. Nothing has left at this point.
    private func review() {
        phase = .sending
        Task {
            await GmailSignatureService.refreshBeforeSend()
            pending = SendConfirmation(replyFor: recipient, of: prospect, body: body_)
                .map { PendingReply(confirmation: $0) }
            // A confirmation that cannot be built means the send could not have gone either, so the panel
            // returns to composing rather than sitting on a spinner that will never resolve.
            phase = .compose
        }
    }

    private func send() {
        phase = .sending
        Task {
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

// #2144: the composed reply held while Dan reads it. A wrapper only because SendConfirmation carries no
// identity of its own and `.sheet(item:)` needs one, the same reason PendingRowNudge below has an id.
struct PendingReply: Identifiable {
    let confirmation: SendConfirmation
    var id: String { confirmation.recipient + "|" + confirmation.subject }
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
