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
        case ready([ProposedConversation.Candidate])
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
            case .ready(let candidates) where candidates.isEmpty:
                Text(ProposedConversationCopy.pickNothingFound)
                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            case .ready(let candidates):
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

    private func load() async {
        phase = .reading
        let outcome = await GmailReplySearch().search(in: context)
        switch outcome {
        case .notConnected:
            phase = .failed(ProposedConversationCopy.notConnected)
        case .failed(let reason):
            phase = .failed(reason)
        case .nothingInScope:
            // Not a failure, and not the same as "read the mailbox and found nothing": this pitch is out
            // of the search's scope, so no mailbox was read for it at all (L98).
            phase = .ready([])
        case .searched(let candidates, _, _):
            phase = .ready(ProposedConversation.pickable(candidates, for: recipient, on: prospect,
                                                         selfEmail: SendIdentity.danWright.email))
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
