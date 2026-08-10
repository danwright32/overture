import SwiftUI
import SwiftData

// #2145: the one screen for answering a reply, whatever wrote it.
//
// The Reached out list renders scouted shows and hire inquiries together, and until now they answered
// through two separate implementations of one job, which had already drifted: one showed the message
// being answered and the other did not, one said why a send was refused and the other went quietly dead,
// one confirmed what was about to go out and the other sent immediately. Half the rows in one list
// behaved one way and half the other, which is invisible from inside either file.
//
// What differs by entity arrives in a ReplyComposition the call site builds. This view knows nothing
// about a Prospect or an Inquiry.
//
// A panel over the queue rather than the row growing in place. QueueView's body derives the whole store
// (`makeRenderData`), and `@State` invalidates the view that DECLARES it, so a compose box owning its
// text on that view would re-derive every prospect on every keystroke, which is the defect #1774, #1922
// and #1923 each fought. The typing lives in here, one level down, where it costs one panel.
struct ReplySheet: View {
    let composition: ReplyComposition
    let gmailConnected: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var body_: String
    // #2143: what the box was last given, so a draft landing later can tell text Dan has since written
    // from text he was handed and has not touched.
    @State private var seeded: String
    // #2143: a draft that arrived while he was writing. Held, not applied: replacing words somebody is
    // in the middle of typing is the one thing reading the screen afterwards cannot undo.
    @State private var offeredDraft: String?
    // What he types when the entity has a subject of its own. Empty for one that does not, where it is
    // never read.
    @State private var subject: String
    // #2145: the whole state of the send, carrying the instant each running step began, decided in
    // ReplyPanel where it is tested.
    @State private var phase: ReplyPanel.SendPhase = .composing
    // #2144: what Dan is about to approve, held while he reads it. Nil until Send is pressed, which is
    // deliberate: building it composes the signature onto the body, and hanging that off every keystroke
    // would pay the whole composition per character (L59, L62).
    @State private var pending: PendingReply?

    // #2143: the box opens on the draft already waiting on this contact, seeded at construction rather
    // than in an onAppear, so the screen is never up holding an empty box over a draft that exists, not
    // even for one frame.
    init(composition: ReplyComposition, gmailConnected: Bool) {
        self.composition = composition
        self.gmailConnected = gmailConnected
        let opening = composition.aiDraft?.current().flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        } ?? ""
        _body_ = State(initialValue: opening)
        _seeded = State(initialValue: opening)
        _subject = State(initialValue: composition.editableSubject ?? "")
    }

    // #2152: one decision, asked once. The button's disabled state and the reason on screen come from the
    // same value, so a refusal can never be enforced without being stated.
    private var refusal: ReplyPanel.SendRefusal? {
        composition.refusal(body: body_, gmailConnected: gmailConnected)
    }
    private var canSend: Bool { refusal == nil }
    // Nil for an entity with no subject of its own, which is what tells the refusal rule it can never be
    // refused for one.
    private var typedSubject: String? { composition.editableSubject == nil ? nil : subject }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            header
            theirReply
            if let editable = composition.editableSubject {
                subjectField(placeholder: editable)
            }
            // #2145: the failure sits ABOVE his words rather than in place of them. The sentence tells him
            // he can try again, and the box holding what he wrote has to still be there for that to mean
            // anything (L11).
            if let failure = phase.failure {
                Text(failure).font(OVType.body).foregroundStyle(OVColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
            }
            draftOffer
            if phase.showsComposeBox { compose }
            footer
        }
        .padding(OVSpacing.lg)
        .frame(width: 560)
        // #2143: the drafter is detached, so its result lands on the contact while this screen is open.
        // Reading it here is what makes "Draft with AI" finish somewhere Dan is looking.
        .onChange(of: composition.aiDraft?.current()) { _, arrived in
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

    // MARK: who this is with

    private var header: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xxs) {
            Text(composition.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(OVColor.ink)
            if let subtitle = composition.subtitle, !subtitle.isEmpty {
                Text(subtitle).font(OVType.meta).foregroundStyle(OVColor.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // L64: the audience is stated before the button, because a reply mirrors the addressing of the
            // message it answers and that is routinely not who the original email went to.
            //
            // #2155: one row per address rather than one sentence, so the screen can mark which of them
            // actually wrote and put a remove control on each.
            if composition.audience.isEmpty {
                Text(ReplyPanelCopy.noAddress).font(OVType.meta).foregroundStyle(OVColor.rust)
            } else {
                Text(ReplyPanelCopy.audienceHeading).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                ForEach(ReplyPanel.audienceEntries(composition.audience, writer: composition.writer)) { entry in
                    audienceRow(entry)
                }
                // #2151: the address that wrote is on none of this show's contacts, so say so and offer to
                // save it. Offered rather than done, because whether it is the same person from a second
                // mailbox or a colleague answering for them is a judgement only Dan can make.
                if let stranger = composition.audienceControls?.unknownWriter() {
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
            Button(ReplyPanelCopy.saveWriter) { composition.audienceControls?.saveWriter() }
                .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.forest)
                .help(ReplyPanelCopy.saveWriterHelp)
            Spacer()
        }
        .padding(.top, OVSpacing.xxs)
    }

    private func audienceRow(_ entry: ReplyPanel.AudienceEntry) -> some View {
        HStack(spacing: OVSpacing.xs) {
            Text(entry.address).font(OVType.meta).foregroundStyle(OVColor.ink)
            if entry.wrote {
                Text(ReplyPanelCopy.wroteThis).font(OVType.meta).foregroundStyle(OVColor.forest)
            }
            // Removable only where removing means something: taking an address off a show's reply also
            // stops that show emailing the contact. An inquiry is one person and has no such list.
            if entry.canRemove, let controls = composition.audienceControls {
                // Icon only, so it carries the full sentence as its accessibility label as well as its
                // tooltip: the label is the only place the second half of what it does is stated.
                Button { controls.remove(entry.address) } label: {
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

    // MARK: what they said

    @ViewBuilder private var theirReply: some View {
        if let words = ReplyPanel.theirWords(composition.contact) {
            // #2159: capped, and saying so. An email Dan is answering routinely carries the whole point
            // below the fold (the one that found this listed a season's dates there), and a box that reads
            // as a complete quotation gets answered as one.
            CappedScrollView(maxHeight: 160) {
                Text(words).font(OVType.body).foregroundStyle(OVColor.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(OVSpacing.sm)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(OVColor.surfaceSunk.opacity(0.6)))
        } else if let reason = ReplyPanel.missingWordsReason(composition.contact) {
            // #2149: which of the two reasons, decided beside the data rather than assumed here. Nothing
            // at all when no message was ever received, which is where an inquiry Dan is answering first
            // lands (#2145).
            Text(reason).font(OVType.meta).foregroundStyle(OVColor.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: what he writes

    private func subjectField(placeholder: String) -> some View {
        TextField(placeholder, text: $subject)
            .textFieldStyle(.roundedBorder)
            .disabled(phase.freezesComposeBox)
    }

    // #2145: the three pieces of the compose box as one value, so the rules about what may replace what
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
    // "I'll respond to whatever it is they say, usually by hand without needing AI to write it, although I
    // should be given the option to trigger an AI written draft if i choose too (that's not the default in
    // that situation though)."
    private var compose: some View {
        TextEditor(text: $body_)
            .font(OVType.body)
            .frame(minHeight: 160)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(OVColor.line))
            // #2145: read-only only while the mail is actually going, so an edit cannot land on words
            // already handed to Gmail. A failure is the state he retries FROM, so it stays editable.
            .disabled(phase.freezesComposeBox)
    }

    // MARK: what he can do

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
            // #2145: refused once the mail is going. Dismissing then took the screen down with the
            // outcome still to come, so a send that failed looked exactly like one that worked (L12).
            Button(ReplyPanelCopy.cancel) { dismiss() }
                .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                .disabled(!phase.allowsCancel)
            draftControl
            Spacer()
            // #2145: the label names WHICH step is running, and counts from the instant that step began
            // rather than from this redraw. Anchored on `Date()`, the counter restarted whenever anything
            // on the screen changed, so the stall timeout could never be reached (L74).
            if let running = phase.runningLabel {
                LiveRunLabel(base: running, since: phase.startedAt, timeout: RunTimeouts.send,
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

    // #2143: the run stays on the screen that started it. Pressing the button used to dismiss the sheet,
    // which put the only trace of a paid run that was under way (and of the draft it came back with) on
    // the Archive card Dan does not open, so working, still-alive and stalled were all the same silence.
    // Read from the contact rather than from a flag of this view's own, so opening the screen onto a run
    // already under way shows it too (L14).
    //
    // Absent entirely for an entity with no drafter, rather than a control that could not work.
    @ViewBuilder private var draftControl: some View {
        if let draft = composition.aiDraft {
            if draft.isRunning() {
                LiveRunLabel(base: ReplyPanelCopy.drafting, since: draft.requestedAt(),
                             timeout: RunTimeouts.replyDraft, font: OVType.meta, color: OVColor.inkSoft,
                             onRetry: { draft.request() },
                             heartbeat: { ReplyClassifyService.heartbeat(now: Date()) })
            // #2129: offered, never automatic. Dan writes these himself and presses this only if he wants
            // to. Scoped to THIS reply, so it spends on the one conversation he asked about.
            } else if phase.runningLabel == nil {
                Button(ReplyPanelCopy.draftWithAI) { draft.request() }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.forest)
                    .help(ReplyPanelCopy.draftWithAIHelp)
            }
        }
    }

    // #2144: step one of sending, and the only thing the Send button does. Refreshes the signature FIRST
    // so the message Dan reads carries the signature the send will actually compose, then puts the whole
    // composed email in front of him. Nothing has left at this point.
    private func review() {
        // #2145: PREPARING, not sending. Nothing has left, and he has not yet seen what he would approve.
        phase = .preparing(since: Date())
        Task {
            await GmailSignatureService.refreshBeforeSend()
            guard let confirmation = composition.confirmation(body_, typedSubject) else {
                // #2145: a confirmation that cannot be built means the send could not have gone either,
                // and the button pressing to no visible effect is the same silence as a dead control. Say
                // so instead of dropping back to composing with nothing changed (L11, L67).
                phase = .failed(ReplyPanelCopy.couldNotPrepare)
                return
            }
            pending = PendingReply(confirmation: confirmation)
            phase = .composing
        }
    }

    private func send() {
        phase = .sending(since: Date())
        Task {
            let sent = await composition.send(body_, typedSubject)
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
