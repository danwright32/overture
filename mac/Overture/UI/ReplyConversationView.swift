import SwiftUI

// #2127: the reply surface for one contact who wrote back, in ONE place.
//
// It used to be `DraftReviewView.replyDraftBlock`, private to that view, which is why answering a reply
// was only possible from the Archive card. The Reached out stage renders its own lightweight rows
// (QueueView, `focusedStage == .reachedOut`) and so had no route to it at all, and Dan's rule is that
// Archive is for things that are done: "I'm never going to archive unless I need to look at something in
// the past" (2026-08-05).
//
// A standalone view taking explicit props rather than a method on its host, for the reason FollowUpsView
// states about its own row: threading everything explicitly is what makes it reachable from a test at
// all. Its editing state lives INSIDE it, so two hosts can show a reply at once without sharing one
// editing slot and fighting over it.
struct ReplyConversationView: View {
    let contact: RecipientSnapshot
    // The lint's inputs, taken as plain values rather than a QueueItem: building a QueueItem runs
    // SendGroup.CardGroups, which runs the draft lint over every contact's whole letter, and a row must
    // not pay that merely to render (L62).
    let lintTitle: String
    let knownsDate: Bool
    let knownsVenue: Bool
    let gmailConnected: Bool
    // Non-nil while this contact's reply is in flight. Read by the host from its own send-state holder,
    // never from the queue's derivation, so a send in progress redraws this row and nothing else.
    let sendingSince: Date?

    var onDraftReply: (_ recipientId: String) -> Void = { _ in }
    var onSendReply: (_ recipientId: String) -> Void = { _ in }
    var onCopyReply: (_ recipientId: String) -> Void = { _ in }
    var onEditReplyDraft: (_ recipientId: String, _ body: String) -> Void = { _, _ in }
    var onCancelReplyDraft: () -> Void = {}

    // Owned here, not by the host. Two hosts rendering this at once would otherwise share one editing
    // slot: opening the editor in the queue would open it in the Archive card too, and Cancel in one
    // would close the other.
    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let hint = contact.intentHint, !hint.isEmpty {
                Text(QueueModel.aiReadNote(hint: hint))
                    .font(OVType.tag).foregroundStyle(OVColor.inkFaint)
            }
            if isEditing {
                editor
            } else if contact.hasReplyDraft {
                draft
            } else if contact.isDraftingReply {
                drafting
            } else {
                Button("Draft a reply") { onDraftReply(contact.id) }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.forestText)
                    .padding(.horizontal, OVSpacing.sm).padding(.vertical, 4)
                    .background(Capsule().strokeBorder(OVColor.forest.opacity(0.4), lineWidth: 1))
            }
        }
        .padding(.leading, 20)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $editText)
                .font(OVType.body).frame(minHeight: 90).padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(OVColor.line))
            HStack(spacing: OVSpacing.xs) {
                Button("Save") { onEditReplyDraft(contact.id, editText); isEditing = false }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Cancel") { isEditing = false }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            }
        }
    }

    private var draft: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(contact.replyDraftBody ?? "")
                .font(OVType.body).foregroundStyle(OVColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(OVSpacing.sm)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(OVColor.surfaceSunk.opacity(0.6)))
            // #846: same two separate tags as the cold draft, for the same reason. A reply goes to
            // somebody who already wrote back to him, so it is the LAST place the trace should be missing.
            HStack(spacing: 6) {
                // #2131: says which it is. A reply Dan typed himself is not an edit of anything, and
                // calling it one told him the card had an earlier version that never existed.
                if let author = contact.replyAuthorLabel {
                    Text(author).font(.system(size: 10)).foregroundStyle(OVColor.gold)
                }
                if let trace = contact.replyDraftTraceLabel {
                    Text(trace).font(.system(size: 10)).foregroundStyle(OVColor.inkFaint)
                }
            }
            // #456 / #459: flag a reply draft that asks for the date/venue this show already carries, the
            // same as the cold path, suppressed once Dan edits (logic in replyDraftFindings).
            DraftIssueFlags(findings: contact.replyDraftFindings(title: lintTitle,
                                                                 knownsDate: knownsDate,
                                                                 knownsVenue: knownsVenue))
            // #2063: who else reads this, shown only when the reply reaches somebody besides the contact
            // whose row this is. A reply mirrors the addressing of the message it answers, which is a fact
            // about that message, so approving the words has to mean approving the audience too (L64).
            if let alsoReaches = QueueModel.replyAlsoReachesLabel(contact.replyAlsoReaches) {
                Text(alsoReaches).font(OVType.tag).foregroundStyle(OVColor.gold)
            }
            if let sendingSince {
                LiveRunLabel(base: "Sending reply", since: sendingSince, timeout: RunTimeouts.send,
                             font: OVType.meta, color: OVColor.inkSoft, onRetry: { onSendReply(contact.id) })
            } else {
                actions
            }
        }
    }

    // #2546: why Send reply is refusing, from the same call that decides whether it is.
    //
    // The address is now part of the gate, where before it was not: the button was enabled for a contact
    // with no address, and SendService.sendReplyDraft refuses a blank one on its first line, so the press
    // returned false and nothing happened at all. Code that has already detected a missing required value
    // must block the action rather than let it run and fail silently (L67).
    private var sendRefusal: String? {
        SendGate.reason(gmailConnected: gmailConnected, hasAddress: SendGate.hasAddress(contact.email))
    }

    private var actions: some View {
        HStack(alignment: .firstTextBaseline, spacing: OVSpacing.xs) {
            Button { onSendReply(contact.id) } label: {
                Label("Send reply", systemImage: "paperplane")
                    .font(OVType.meta).foregroundStyle(OVColor.onForest)
                    .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                    .background(Capsule().fill(OVColor.forest))
            }
            .buttonStyle(.plain).disabled(sendRefusal != nil)
            // A dimmed control with no label is unreadable to VoiceOver as well as to the eye.
            .accessibilityHint(sendRefusal ?? "")
            .help(sendRefusal ?? "Send this reply on the contact's thread")
            // Said on screen and not only in the tooltip, which is invisible at rest (L49).
            ControlRefusalLine(reason: sendRefusal)
            Button("Edit") { editText = contact.replyDraftBody ?? ""; isEditing = true }
                .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.forestText)
            Button("Copy") { onCopyReply(contact.id) }
                .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.forestText)
                .help("Copy the draft and mark it replied (paste it into Gmail yourself)")
        }
    }

    private var drafting: some View {
        // #436: past the stall timeout this flips to a visible "looks stuck" state with a Retry (re-stamps
        // and re-launches the draft) instead of an indefinite spinner. #1038: a Cancel beside it stops the
        // detached run cooperatively, so Dan can abandon a drafting run he no longer wants.
        HStack(spacing: OVSpacing.xs) {
            // #1085: the run's "N of M" count is a single run-wide fact, so it lives once at the top of the
            // queue, not repeated on every recipient this run is drafting. This per-recipient label keeps
            // its own genuinely per-recipient states: spinner plus elapsed, a stall timeout that flips to
            // Retry, and the run's real heartbeat, so working, still-alive and stalled stay distinguishable.
            // #2143: the panel says this too, in the same words, from the one constant.
            LiveRunLabel(base: ReplyPanelCopy.drafting, since: contact.replyDraftRequestedAt,
                         timeout: RunTimeouts.replyDraft,
                         font: OVType.meta, color: OVColor.inkSoft,
                         onRetry: { onDraftReply(contact.id) },
                         heartbeat: { ReplyClassifyService.heartbeat(now: Date()) })
            Button("Cancel") { onCancelReplyDraft() }
                .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.rust)
                .help("Stop the reply drafting run")
        }
    }
}

// #2127: the draft lint's findings, extracted alongside the reply block because both the cold draft and
// the reply draft render them and only one of the two hosts could reach the private version.
struct DraftIssueFlags: View {
    let findings: [DraftIssue]

    var body: some View {
        if !findings.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(findings, id: \.self) { f in
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(f.label)
                    }
                    .font(OVType.tag).foregroundStyle(OVColor.rust)
                }
            }
            .padding(.top, 2)
        }
    }
}
