import SwiftUI
import SwiftData

// #2718: Dan's manual route. His words: "I'll also need a way to tell it about the email if there's a
// situation where it doesn't propose but I got an email anyway."
//
// It reads the mailbox and shows him everything the search FOUND for this pitch, best first, rather than
// only the one that scored high enough to be proposed. That is the whole point: the case this exists for
// is a message the scorer found and did not back, either because it scored below the floor or because it
// tied with another.
//
// It does NOT let him past the refusals (`ProposedConversation.pickable` applies them). Picking by hand
// is Dan overriding the SCORE, a judgement about who is most likely. It is not him overriding "never the
// room's own address" or "never a press desk", which the product has held since #368 and #635, and a
// hand route that skipped those would be a side door into the exact defect the guards exist for.
struct LinkReplyPicker: View {
    let prospect: Prospect
    let recipient: Recipient
    var onDismiss: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(ActionFeedback.self) private var feedback

    // Three visibly different states, never one indefinite spinner: reading, a result, or a failure that
    // says what went wrong and can be tried again.
    private enum Phase: Equatable {
        case reading
        case failed(String)
        // #3708: no pitch date, so no window. Its own state and never an empty list: a contact Overture
        // cannot read for and a mailbox holding no answer are different things, and only the second is
        // something this screen is entitled to tell him (L98).
        case noPitchDate
        // `stoppedShort` rides the ready case rather than replacing it, for the reason `saveFailed` rides
        // `.searched`: a truncated read really did read, and the candidates it found are true and worth
        // picking from. What is in doubt is only whether the answer could be OLDER than what it saw.
        case ready([ProposedConversation.Candidate], stoppedShort: GmailReplySearch.StopReason?)
    }

    @State private var phase: Phase = .reading
    @State private var linking: String?

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            Text(ProposedConversationCopy.pickTitle)
                .font(OVType.groupName).foregroundStyle(OVColor.ink)
            Text(prospect.groupName).font(OVType.meta).foregroundStyle(OVColor.inkSoft)

            switch phase {
            case .reading:
                HStack(spacing: OVSpacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(ProposedConversationCopy.reading)
                        .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                }
            case .failed(let reason):
                Text(reason).font(OVType.meta).foregroundStyle(OVColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
                Button(ProposedConversationCopy.tryAgain) { Task { await load() } }
                    .font(OVType.meta)
            case .noPitchDate:
                Text(ProposedConversationCopy.pickNoPitchDate)
                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            case .ready(let candidates, let stoppedShort) where candidates.isEmpty:
                // A truncated read that found nothing must NOT say it read the inbox and found nothing:
                // it read the newest stretch of the window, which is a different claim (L98).
                Text(stoppedShort == nil
                     ? ProposedConversationCopy.pickNothingFound
                     : ProposedConversationCopy.pickStoppedShort(examined: GmailReplySearch.maxMessagesOnDemand))
                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            case .ready(let candidates, let stoppedShort):
                // Above the list, not under it: it changes how the list should be read, and a caveat
                // below a scrolling region is one he may never reach.
                if stoppedShort != nil {
                    Text(ProposedConversationCopy.pickStoppedShort(examined: GmailReplySearch.maxMessagesOnDemand))
                        .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // #2159/L76: macOS hides scrollbars until a gesture starts, so a plain capped ScrollView
                // is pixel-identical at rest to one showing everything it has, and Dan would answer only
                // what he could see. This list can genuinely run long: a month of inbound mail can hold
                // several plausible senders.
                CappedScrollView(maxHeight: 320) {
                    VStack(alignment: .leading, spacing: OVSpacing.sm) {
                        ForEach(candidates, id: \.messageId) { candidate in
                            row(candidate)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button(ProposedConversationCopy.close) { onDismiss() }.font(OVType.meta)
            }
        }
        .padding(OVSpacing.lg)
        .frame(width: 460)
        .task { await load() }
    }

    @ViewBuilder
    private func row(_ candidate: ProposedConversation.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ProposedConversationCopy.sender(name: candidate.fromName, address: candidate.fromAddress))
                .font(OVType.body).foregroundStyle(OVColor.ink)
            Text(ProposedConversationCopy.detail(subject: candidate.subject,
                                                 sentAt: candidate.sentAt, now: Date()))
                .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            // What linking DOES, on every row, because each row would save a DIFFERENT address and what
            // Dan approves has to be exactly what happens including who it reaches (L64).
            Text(ProposedConversationCopy.confirmDetail(address: candidate.fromAddress))
                .font(.system(size: 10)).foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            if linking == candidate.messageId {
                HStack(spacing: OVSpacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(ProposedConversationCopy.linking).font(OVType.meta)
                        .foregroundStyle(OVColor.inkSoft)
                }
            } else {
                Button(ProposedConversationCopy.confirm) { Task { await link(candidate) } }
                    .font(OVType.meta)
            }
        }
        .padding(.vertical, 4)
    }

    // #3708: reads on demand, for THIS contact, back to its own pitch.
    //
    // It used to call the tick's own `search(in:)`, which meant this screen
    // could only ever offer what the automatic scope was already looking at. That scope refuses anything
    // holding a conversation, so on an emailed pitch it answered `nothingInScope` and the picker
    // correctly reported that no mailbox had been read: the control was reachable and could never find
    // anything. Widening the scope was the wrong fix, since it is the read the reconcile tick makes
    // every thirty minutes (#3708 states the cost).
    private func load() async {
        phase = .reading
        // No pitch date, no window. Said as its own state rather than searched with a guessed one,
        // because a window Overture invented would offer mail from before the pitch as the answer to it.
        guard let since = recipient.manualSearchAnchor else {
            phase = .noPitchDate
            return
        }
        switch await GmailReplySearch().searchOnDemand(since: since) {
        case .notConnected:
            phase = .failed(ProposedConversationCopy.notConnected)
        case .failed(let reason):
            phase = .failed(reason)
        case .read(let candidates, let stoppedShort):
            phase = .ready(ProposedConversation.pickable(candidates, for: recipient, on: prospect,
                                                         selfEmail: SendIdentity.danWright.email),
                           stoppedShort: stoppedShort)
        }
    }

    private func link(_ candidate: ProposedConversation.Candidate) async {
        linking = candidate.messageId
        // Routed through the SAME propose-then-confirm pair the automatic path uses, rather than calling
        // the attach directly, so a hand link and a confirmed proposal cannot end up writing different
        // things (L16 applied to a write rather than a count).
        ProposedConversation.clear(on: recipient)
        ProposedConversation.propose(candidate, on: recipient, now: Date())
        let outcome = await ConfirmProposedConversation().confirm(on: recipient, of: prospect, in: context)
        linking = nil
        switch outcome {
        case .notConnected:
            phase = .failed(ProposedConversationCopy.notConnected)
        case .failed(let reason), .refused(let reason):
            feedback.acknowledge(reason, tone: .warning)
        case .attached(_, let saveFailed):
            feedback.acknowledge(saveFailed ? ProposedConversationCopy.couldNotSaveLink
                                            : ProposedConversationCopy.linked,
                                 tone: saveFailed ? .warning : .info)
            onDismiss()
        }
    }
}
