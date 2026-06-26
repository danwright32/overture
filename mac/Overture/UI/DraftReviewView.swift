import SwiftUI

// The Trigger-2 review surface, shown inside a row once the Prep run has found a
// contact and drafted an email. Dan reads the contact (with its confidence), edits
// the draft inline if he likes, then approves or skips. Approving is what later
// hands the email to the throttled Gmail send.
struct DraftReviewView: View {
    let item: QueueItem
    let onApprove: () -> Void
    let onUnapprove: () -> Void
    let onSkip: () -> Void
    let onSaveDraft: (_ subject: String, _ body: String) -> Void
    var onSetOutcome: (Outcome) -> Void = { _ in }
    var onSetLostReason: (String) -> Void = { _ in }
    var onSend: () -> Void = {}
    var onSetConversationState: (ConversationState) -> Void = { _ in }
    var gmailConnected: Bool = false

    @State private var editing = false
    @State private var draftSubject = ""
    @State private var draftBody = ""
    @State private var lostReason = ""
    @State private var lostReasonSeeded = false

    private var isApproved: Bool { item.status == .approved }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            contactLine
            draftBlock
            actionRow
            if item.isLost { lostReasonField }
        }
        .padding(OVSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OVColor.surfaceSunk.opacity(0.5))
        )
    }

    @ViewBuilder private var contactLine: some View {
        HStack(spacing: OVSpacing.xs) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(OVColor.inkFaint)
            if let name = item.contactName {
                Text(name).fontWeight(.medium).foregroundStyle(OVColor.ink)
                if let role = item.contactRole {
                    Text(role).foregroundStyle(OVColor.inkFaint)
                }
            } else if let email = item.contactEmail {
                Text(email).foregroundStyle(OVColor.ink)
            } else {
                Text("No contact found").foregroundStyle(OVColor.inkFaint)
            }
            if let conf = item.contactConfidence {
                ConfidencePip(confidence: conf)
            }
            Spacer()
            if let email = item.contactEmail {
                Text(email).font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
            }
        }
        .font(.system(size: 12))
    }

    @ViewBuilder private var draftBlock: some View {
        if editing {
            VStack(alignment: .leading, spacing: OVSpacing.xs) {
                TextField("Subject", text: $draftSubject)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $draftBody)
                    .font(OVType.body)
                    .frame(minHeight: 120)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(OVColor.line))
                HStack {
                    Button("Save") {
                        onSaveDraft(draftSubject, draftBody)
                        editing = false
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Cancel") { editing = false }
                        .buttonStyle(.plain).foregroundStyle(OVColor.inkSoft)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if let subject = item.draftSubject {
                    Text(subject).font(.system(size: 13, weight: .semibold)).foregroundStyle(OVColor.ink)
                }
                if let body = item.draftBody {
                    Text(body)
                        .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if item.draftEditedByDan {
                    Text("Edited").font(.system(size: 10)).foregroundStyle(OVColor.gold)
                }
                draftCheckFlags
            }
        }
    }

    // Self-check findings (#11): voice / AI-tells / stance issues in the draft, surfaced so
    // Dan's review is judgment, not cleanup. Only on an unedited draft from the run — once
    // Dan edits it, it's his.
    @ViewBuilder private var draftCheckFlags: some View {
        if !item.draftEditedByDan, let body = item.draftBody {
            let findings = DraftCheck.findings(in: body)
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

    private var actionRow: some View {
        HStack(spacing: OVSpacing.xs) {
            if item.isSent {
                Label("Sent", systemImage: "paperplane.fill")
                    .font(OVType.meta).foregroundStyle(OVColor.forest)
                Spacer()
                conversationStatePicker
                outcomePicker
            } else if isApproved {
                Button { onSend() } label: {
                    Label("Send", systemImage: "paperplane")
                        .font(OVType.meta).foregroundStyle(OVColor.onForest)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                        .background(Capsule().fill(OVColor.forest))
                }
                .buttonStyle(.plain)
                .disabled(!gmailConnected || item.contactEmail == nil)
                .help(gmailConnected ? "Send this email now" : "Connect Gmail first")
                Button("Unapprove") { onUnapprove() }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                if let err = item.sendError {
                    Text(err).font(.system(size: 10)).foregroundStyle(OVColor.rust).lineLimit(1)
                }
                Spacer()
            } else {
                Button { onApprove() } label: {
                    Text("Approve").font(OVType.meta).foregroundStyle(OVColor.onForest)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                        .background(Capsule().fill(OVColor.forest))
                }
                .buttonStyle(.plain)
                .disabled(item.contactEmail == nil)
                Button("Edit") {
                    draftSubject = item.draftSubject ?? ""
                    draftBody = item.draftBody ?? ""
                    editing = true
                }
                .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                Button("Skip") { onSkip() }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            }
            if !isApproved { Spacer() }
        }
    }

    // Shown once sent: defaults to No response (most prospects), Dan marks exceptions.
    // Replied/Booked also arrive automatically later (Gmail/Downbeat); see Outcome.
    private var outcomePicker: some View {
        Menu {
            ForEach(Outcome.allCases, id: \.self) { o in
                Button {
                    onSetOutcome(o)
                } label: {
                    if item.outcome == o { Label(o.label, systemImage: "checkmark") }
                    else { Text(o.label) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(outcomeColor).frame(width: 6, height: 6)
                Text(item.outcome.label).font(OVType.meta)
            }
            .foregroundStyle(OVColor.inkSoft)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // Where the conversation stands once the lead has replied (#111): Dan tags it so the right
    // event-aware reminder fires. Setting an active state also marks the lead replied; declined
    // resolves it to lost-soft. Shown beside the outcome once sent.
    private var conversationStatePicker: some View {
        Menu {
            ForEach(ConversationState.allCases, id: \.self) { s in
                Button {
                    onSetConversationState(s)
                } label: {
                    if item.conversationState == s { Label(s.label, systemImage: "checkmark") }
                    else { Text(s.label) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let state = item.conversationState {
                    Circle().fill(state.accent).frame(width: 6, height: 6)
                    Text(state.label).foregroundStyle(OVColor.ink)
                } else {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text("Set conversation").foregroundStyle(OVColor.inkSoft)
                }
            }
            .font(OVType.meta)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Where this conversation stands")
    }

    // Always visible once Dan marks a lead lost: an optional note for his own reference
    // (it doesn't change the ranking, which is driven by the soft/hard choice).
    private var lostReasonField: some View {
        HStack(spacing: OVSpacing.xs) {
            Image(systemName: "text.bubble")
                .font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
            TextField("Why lost? (optional note)", text: $lostReason)
                .textFieldStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.ink)
                .onSubmit { onSetLostReason(lostReason) }
                .onChange(of: lostReason) { _, newValue in
                    if lostReasonSeeded { onSetLostReason(newValue) }
                }
        }
        .padding(.horizontal, OVSpacing.xs).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(OVColor.surfaceSunk.opacity(0.5)))
        .onAppear {
            lostReason = item.lostReason ?? ""
            lostReasonSeeded = true
        }
    }

    private var outcomeColor: Color {
        switch item.outcome {
        case .booked: return OVColor.forest
        case .replied: return OVColor.gold
        case .lostSoft: return OVColor.inkSoft
        case .lostHard: return OVColor.rust
        case .noResponse: return OVColor.inkFaint
        }
    }
}

#Preview("Draft review (sent, conversation)") {
    var item = QueueItem(
        id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Carnegie Hall",
        performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
        priorRelationship: "warm", production: "self", profile: "strong", coverage: "likely_uncovered",
        fitScore: 8, tier: "high", fitReason: "Repeat-client-adjacent ensemble at a flagship venue.",
        matchedClientName: "Aurora Strings", possibleMatchSource: nil, possibleMatchName: nil, status: .approved)
    item.contactName = "Emma Robinson"
    item.contactRole = "Marketing & Communications Manager"
    item.contactEmail = "emma@aurorastrings.example"
    item.contactConfidence = .high
    item.draftSubject = "Photographing Aurora Strings at Carnegie Hall."
    item.draftBody = "Hi Emma, I photograph performing arts in New York and saw Aurora Strings is at Carnegie Hall. I shoot unobtrusive, no-flash documentary coverage and think it would suit this program."
    item.sentAt = Date()
    item.conversationState = .wantsToBook
    return DraftReviewView(item: item, onApprove: {}, onUnapprove: {}, onSkip: {}, onSaveDraft: { _, _ in })
        .padding(OVSpacing.lg)
        .frame(width: 480)
        .background(OVColor.canvas)
}

// The accent for a conversation state, shared by the lead-row picker and the Due list so a state
// reads the same everywhere: forest = on track to book, gold = warm, rust = needs a response.
extension ConversationState {
    var accent: Color {
        switch self {
        case .wantsToBook: return OVColor.forest
        case .interested: return OVColor.gold
        case .hasQuestion: return OVColor.rust
        case .declined: return OVColor.inkSoft
        }
    }
}

private struct ConfidencePip: View {
    let confidence: ContactConfidence
    var body: some View {
        let (label, color): (String, Color) = {
            switch confidence {
            case .high: return ("high confidence", OVColor.forest)
            case .medium: return ("medium confidence", OVColor.gold)
            case .low: return ("low confidence", OVColor.rust)
            }
        }()
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
