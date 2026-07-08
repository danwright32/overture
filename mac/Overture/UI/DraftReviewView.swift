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
    var onSetLostReason: (String) -> Void = { _ in }
    var onSend: () -> Void = {}
    var onSetConversationState: (ConversationState) -> Void = { _ in }
    var onConfirmConversationState: () -> Void = {}
    var onDismissReply: () -> Void = {}
    // Per-contact manual-judge marking (#418 B1/B2): resolution nil + bounced false = "In conversation".
    var onMarkContact: (_ recipientId: String, _ resolution: RecipientResolution?, _ bounced: Bool) -> Void = { _, _, _ in }
    var onDismissContactReply: (_ recipientId: String) -> Void = { _ in }
    var onDismissContactBounce: (_ recipientId: String) -> Void = { _ in }
    var onAddRecipient: (_ email: String, _ name: String?) -> Void = { _, _ in }
    var onRemoveRecipient: (_ recipientId: String) -> Void = { _ in }
    // AI reply drafter (#420 C6 / #421): request a draft, send it on the contact's thread, or copy it out.
    var onDraftReply: (_ recipientId: String) -> Void = { _ in }
    var onSendReply: (_ recipientId: String) -> Void = { _ in }
    var onCopyReply: (_ recipientId: String) -> Void = { _ in }
    var onEditReplyDraft: (_ recipientId: String, _ body: String) -> Void = { _, _ in }
    var gmailConnected: Bool = false
    // #436: when this outbound draft is mid-send, the instant it was launched (nil = not sending), so the
    // Send button is replaced by a live "Sending… m:ss" indicator that flips to "looks stuck" past the
    // send timeout. No retry here: a second click could double-send, so recovery is the await resolving.
    var outboundSendSince: Date? = nil
    // Same, keyed per recipient for an in-flight reply send.
    var replySendSince: (_ recipientId: String) -> Date? = { _ in nil }

    @State private var editing = false
    @State private var draftSubject = ""
    @State private var draftBody = ""
    @State private var editingReplyFor: String?    // recipient id whose reply draft is being edited (#423 E)
    @State private var replyEditText = ""
    @State private var lostReason = ""
    @State private var lostReasonSeeded = false
    @State private var showAddContact = false
    @State private var addContactEmail = ""
    @State private var addContactName = ""

    private var isApproved: Bool { item.status == .approved }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            contactLine
            draftBlock
            performerOverridePreviews
            actionRow
            conversationContactsSection
            conversationSuggestionRow
            if item.isLost { lostReasonField }
        }
        .padding(OVSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OVColor.surfaceSunk.opacity(0.5))
        )
    }

    @ViewBuilder private var contactLine: some View {
        let display = ContactDisplay.from(name: item.contactName, role: item.contactRole,
                                          email: item.contactEmail, formURL: item.contactFormURL)
        HStack(spacing: OVSpacing.xs) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(OVColor.inkFaint)
            switch display {
            case let .person(name, role, _):
                Text(name).fontWeight(.medium).foregroundStyle(OVColor.ink)
                if let role { Text(role).foregroundStyle(OVColor.inkFaint) }
            case let .email(email):
                Text(email).foregroundStyle(OVColor.ink)
            case let .form(url):
                Link(destination: url) { Label("Contact form", systemImage: "link") }
                    .foregroundStyle(OVColor.forest)
            case .none:
                Text("No contact found").foregroundStyle(OVColor.inkFaint)
            }
            if let conf = item.contactConfidence {
                ConfidencePip(confidence: conf)
            }
            Spacer()
            // The address is echoed small on the right only for a named contact (name on the left,
            // email on the right); the email-only case already shows it on the left, so no repeat.
            if case let .person(_, _, email?) = display {
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
    // Dan's review is judgment, not cleanup. Only on an unedited draft from the run: once
    // Dan edits it, it's his.
    @ViewBuilder private var draftCheckFlags: some View {
        if !item.draftEditedByDan, let body = item.draftBody {
            issueFlags(DraftCheck.findings(in: body,
                                           knownsDate: item.performanceDate != nil,
                                           knownsVenue: item.venue != nil))
        }
    }

    // #642 (#634 Phase D): a directly-addressed performer's own draft, shown BEFORE Dan approves or
    // sends, not just after (the per-recipient conversationContactsSection below only appears once
    // isSent). Read-only for now; editing an override is deferred to a later phase.
    @ViewBuilder private var performerOverridePreviews: some View {
        ForEach(item.contacts.filter { $0.overrideBody?.isEmpty == false }) { c in
            VStack(alignment: .leading, spacing: 2) {
                Text("\(c.displayName) will instead receive:")
                    .font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
                Text(c.overrideBody ?? "")
                    .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // The shared warning-row rendering for any DraftCheck findings, used by both the cold draft
    // review above and the reply draft below (#456) so there is one surface, not two.
    @ViewBuilder private func issueFlags(_ findings: [DraftIssue]) -> some View {
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

    private var actionRow: some View {
        HStack(spacing: OVSpacing.xs) {
            // "Sent" only once EVERY recipient has gone. A multi-recipient show keeps the Send button
            // (it stays approved with a pending recipient) even after the first email, so each recipient
            // gets its own click (#394).
            if item.isSent && !item.hasPendingRecipient {
                Label("Sent", systemImage: "paperplane.fill")
                    .font(OVType.meta).foregroundStyle(OVColor.forest)
                Spacer()
                if item.isAutoReplied {
                    Button("Not a real reply") { onDismissReply() }
                        .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                        .help("This was not a genuine reply (an auto-reply or out of office). Revert it; a new reply will still flag.")
                }
                if item.conversationStateSource != .auto { conversationStatePicker }   // auto -> own row below
                derivedStatusLabel
            } else if isApproved {
                if let since = outboundSendSince {
                    LiveRunLabel(base: "Sending", since: since, timeout: RunTimeouts.send,
                                 font: OVType.meta, color: OVColor.inkSoft)
                } else {
                    Button { onSend() } label: {
                        Label("Send", systemImage: "paperplane")
                            .font(OVType.meta).foregroundStyle(OVColor.onForest)
                            .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                            .background(Capsule().fill(OVColor.forest))
                    }
                    .buttonStyle(.plain)
                    .disabled(!gmailConnected || !item.hasPendingRecipient)
                    .help(gmailConnected ? "Send this email now" : "Connect Gmail first")
                    Button("Unapprove") { onUnapprove() }
                        .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    if let line = SendFailureLine.text(for: item.sendError) {
                        Text(line).font(.system(size: 10)).foregroundStyle(OVColor.rust).lineLimit(1)
                    }
                }
                Spacer()
            } else {
                Button { onApprove() } label: {
                    Text("Approve").font(OVType.meta).foregroundStyle(OVColor.onForest)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                        .background(Capsule().fill(OVColor.forest))
                }
                .buttonStyle(.plain)
                // #399: was item.contactEmail == nil, the legacy singular field a separate in-flight
                // milestone (#650-654) is slated to delete. hasPendingRecipient already means "at
                // least one recipient still pending with a real address", the same thing this gate
                // needs, so nothing new had to be added.
                .disabled(!item.hasPendingRecipient)
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

    // Per-contact conversation surface (#418 B1): once a show is sent, list each contact with its
    // status and the manual-judge controls. Dan reads the reply in Gmail, then marks the outcome here.
    @ViewBuilder private var conversationContactsSection: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            Text("Contacts")
                .font(OVType.tag).foregroundStyle(OVColor.inkFaint).tracking(0.6)
            if item.contacts.isEmpty {
                Text("No contacts yet.").font(OVType.body).foregroundStyle(OVColor.inkFaint)
            } else {
                ForEach(item.contacts) { contactRow($0) }
            }
            addContactButton
        }
        .padding(.top, OVSpacing.xs)
    }

    // #399: opens a small popover to type an email (required) and name (optional). The add itself
    // runs the duplicate/venue check (ManualRecipientCheck via ProspectMutations); this view never
    // blocks the add on its own, it only requires a plausible email before enabling the button.
    private var addContactButton: some View {
        Button { showAddContact = true } label: {
            Label("Add contact", systemImage: "plus.circle")
                .font(OVType.meta).foregroundStyle(OVColor.forest)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAddContact, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: OVSpacing.sm) {
                Text("Add a contact").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                TextField("Email", text: $addContactEmail)
                    .textFieldStyle(.roundedBorder)
                TextField("Name (optional)", text: $addContactName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Add") {
                        onAddRecipient(addContactEmail, addContactName.isEmpty ? nil : addContactName)
                        addContactEmail = ""
                        addContactName = ""
                        showAddContact = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!addContactEmail.contains("@"))
                    Button("Cancel") { showAddContact = false }
                        .buttonStyle(.plain).foregroundStyle(OVColor.inkSoft)
                }
            }
            .padding(OVSpacing.md)
            .frame(width: 260)
        }
    }

    @ViewBuilder private func contactRow(_ c: RecipientSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: OVSpacing.xs) {
                Image(systemName: "person.crop.circle").foregroundStyle(OVColor.inkFaint)
                Text(c.displayName).fontWeight(.medium).foregroundStyle(OVColor.ink)
                Text(provenanceLabel(c.provenance)).font(OVType.tag).foregroundStyle(OVColor.inkFaint)
                Spacer()
                Text(c.statusLabel).font(OVType.meta).foregroundStyle(contactStatusColor(c))
            }
            .font(.system(size: 12))
            // #642 (#634 Phase D): a performer's direct-address draft, shown read-only so Dan can see
            // exactly what THIS contact will receive instead of the shared (third-person) draft above.
            // Editing this override is not built yet (deferred to a later phase).
            if let overrideBody = c.overrideBody, !overrideBody.isEmpty {
                Text("Will receive: \(overrideBody)")
                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            if let reply = c.lastReplyText, !reply.isEmpty {
                Text(reply)
                    .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            if c.sendState == .sent {
                HStack(spacing: OVSpacing.xs) {
                    Menu {
                        Button("In conversation") { onMarkContact(c.id, nil, false) }
                        Button("Booked") { onMarkContact(c.id, .booked, false) }
                        Button("Closed (not now)") { onMarkContact(c.id, .declinedSoft, false) }
                        Button("Closed (not interested)") { onMarkContact(c.id, .declinedHard, false) }
                        Button("Bounced") { onMarkContact(c.id, nil, true) }
                        Divider()
                        // #399: distinct from every option above, none of which mean "stop pursuing
                        // without recording an outcome".
                        Button("Remove", role: .destructive) { onRemoveRecipient(c.id) }
                    } label: {
                        Text("Mark…").font(OVType.meta).foregroundStyle(OVColor.forest)
                            .padding(.horizontal, OVSpacing.sm).padding(.vertical, 4)
                            .background(Capsule().strokeBorder(OVColor.forest.opacity(0.4), lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    if c.isAutoReplied {
                        Button("Not a real reply") { onDismissContactReply(c.id) }
                            .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                            .help("This wasn't a genuine reply (an auto-reply or out of office). Revert it; a new reply still flags.")
                    }
                    if c.isAutoBounced {
                        Button("Not really bounced") { onDismissContactBounce(c.id) }
                            .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                            .help("This wasn't a genuine bounce. Revert it; a new bounce still flags.")
                    }
                }
                .padding(.leading, 20)
            } else if c.sendState == .pending {
                // #399: a never-sent contact can be removed outright (Prospect.removeOrSuppressRecipient
                // hard-deletes a still-pending row), so this is a plain delete, not a menu of outcomes.
                Button { onRemoveRecipient(c.id) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark.circle").font(.system(size: 10))
                        Text("Remove").font(OVType.meta)
                    }
                    .foregroundStyle(OVColor.inkSoft)
                }
                .buttonStyle(.plain)
                .padding(.leading, 20)
                .help("Remove this contact")
            }
            if c.replied { replyDraftBlock(c) }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, OVSpacing.sm)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(OVColor.surface.opacity(0.6)))
    }

    // The AI reply drafter surface for one replied contact (#420 C6 / #421): a non-binding intent hint,
    // and either the drafted reply (send on the thread / copy out), a "drafting…" progress, or a button
    // to request a draft. Treated as request-response even though the run is detached.
    @ViewBuilder private func replyDraftBlock(_ c: RecipientSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let hint = c.intentHint, !hint.isEmpty {
                Text("AI read: \(QueueModel.replyIntentLabel(hint))")
                    .font(OVType.tag).foregroundStyle(OVColor.inkFaint)
            }
            if editingReplyFor == c.id {
                TextEditor(text: $replyEditText)
                    .font(OVType.body).frame(minHeight: 90).padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(OVColor.line))
                HStack(spacing: OVSpacing.xs) {
                    Button("Save") { onEditReplyDraft(c.id, replyEditText); editingReplyFor = nil }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Cancel") { editingReplyFor = nil }
                        .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                }
            } else if c.hasReplyDraft {
                Text(c.replyDraftBody ?? "")
                    .font(OVType.body).foregroundStyle(OVColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(OVSpacing.sm)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(OVColor.surfaceSunk.opacity(0.6)))
                if c.replyDraftEditedByDan {
                    Text("Edited").font(.system(size: 10)).foregroundStyle(OVColor.gold)
                }
                // #456 / #459: flag a reply draft that asks for the date/venue this show already carries,
                // same as the cold path, but suppressed once Dan edits (logic in replyDraftFindings).
                issueFlags(c.replyDraftFindings(knownsDate: item.performanceDate != nil,
                                                knownsVenue: item.venue != nil))
                if let since = replySendSince(c.id) {
                    LiveRunLabel(base: "Sending reply", since: since, timeout: RunTimeouts.send,
                                 font: OVType.meta, color: OVColor.inkSoft)
                } else {
                    HStack(spacing: OVSpacing.xs) {
                        Button { onSendReply(c.id) } label: {
                            Label("Send reply", systemImage: "paperplane")
                                .font(OVType.meta).foregroundStyle(OVColor.onForest)
                                .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                                .background(Capsule().fill(OVColor.forest))
                        }
                        .buttonStyle(.plain).disabled(!gmailConnected)
                        .help(gmailConnected ? "Send this reply on the contact's thread" : "Connect Gmail first")
                        Button("Edit") { replyEditText = c.replyDraftBody ?? ""; editingReplyFor = c.id }
                            .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.forest)
                        Button("Copy") { onCopyReply(c.id) }
                            .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.forest)
                            .help("Copy the draft and mark it replied (paste it into Gmail yourself)")
                    }
                }
            } else if c.isDraftingReply {
                // #436: past the stall timeout this flips to a visible "looks stuck" state with a Retry
                // (re-stamps and re-launches the draft) instead of an indefinite spinner.
                LiveRunLabel(base: "Drafting a reply", since: c.replyDraftRequestedAt,
                             timeout: RunTimeouts.replyDraft,
                             font: OVType.meta, color: OVColor.inkSoft,
                             onRetry: { onDraftReply(c.id) },
                             runAlive: { ReplyClassifyService.isRunning(now: Date()) })
            } else {
                Button("Draft a reply") { onDraftReply(c.id) }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.forest)
                    .padding(.horizontal, OVSpacing.sm).padding(.vertical, 4)
                    .background(Capsule().strokeBorder(OVColor.forest.opacity(0.4), lineWidth: 1))
            }
        }
        .padding(.leading, 20)
    }

    private func provenanceLabel(_ p: RecipientProvenance) -> String {
        switch p {
        case .act: return "act"
        case .performer: return "performer"
        case .presenter: return "presenter"
        case .manual: return "added"
        }
    }

    private func contactStatusColor(_ c: RecipientSnapshot) -> Color {
        if c.resolution == .booked { return OVColor.forest }
        if c.bounced || c.resolution == .declinedHard { return OVColor.rust }
        if c.replied { return OVColor.gold }
        return OVColor.inkSoft
    }

    // Read-only show status derived from the contacts (#447): the editable lead-level outcome picker
    // is gone, so outcomes are set per contact (the Contacts section below) and the show just reflects
    // them. Booking still arrives lead-level (Confirm booking / Downbeat); see PerformanceStatus.
    private var derivedStatusLabel: some View {
        HStack(spacing: 4) {
            Circle().fill(derivedStatusColor).frame(width: 6, height: 6)
            Text(item.performanceStatus.label).font(OVType.meta)
        }
        .foregroundStyle(OVColor.inkSoft)
        .help("The show's status, read from its contacts. Mark a contact below to change it.")
    }

    // Where the conversation stands once the lead has replied (#111): Dan tags it so the right
    // event-aware reminder fires. Setting an active state also marks the lead replied; declined
    // resolves it to lost-soft. Shown beside the outcome once sent.
    // The plain set/change picker, used in the action row for a lead with no state or a hand-set one.
    private var conversationStatePicker: some View {
        conversationStateMenu(label: nil).help("Where this conversation stands")
    }

    // The AI's read of the reply, on its own line so it reads as a sentence: what the reply looks
    // like, then a clear Confirm (accept onto the timed reminder track) or Change (correct it).
    @ViewBuilder private var conversationSuggestionRow: some View {
        if let state = item.conversationState, item.conversationStateSource == .auto {
            HStack(spacing: OVSpacing.xs) {
                Text("Their reply looks like").foregroundStyle(OVColor.inkSoft)
                Text(state.label).fontWeight(.semibold).foregroundStyle(state.accent.color)
                Spacer()
                Button { onConfirmConversationState() } label: {
                    Text("Confirm").foregroundStyle(OVColor.onForest)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 4)
                        .background(Capsule().fill(OVColor.forest))
                }
                .buttonStyle(.plain)
                conversationStateMenu(label: "Change")
            }
            .font(OVType.meta)
            .padding(.horizontal, OVSpacing.sm).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(state.accent.color.opacity(0.08)))
        }
    }

    private func conversationStateMenu(label: String?) -> some View {
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
                if let label {
                    Text(label)
                } else if let state = item.conversationState {
                    Circle().fill(state.accent.color).frame(width: 6, height: 6)
                    Text(state.label).foregroundStyle(OVColor.ink)
                } else {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text("Set conversation").foregroundStyle(OVColor.inkSoft)
                }
            }
            .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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

    private var derivedStatusColor: Color {
        switch item.performanceStatus {
        case .booked: return OVColor.forest
        case .active: return OVColor.gold
        case .lostDoorOpen: return OVColor.inkSoft
        case .lostNotInterested: return OVColor.rust
        case .new: return OVColor.inkFaint
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

// Maps the domain accent token to a brand colour, shared by the lead-row picker and the Due list so
// a state reads the same everywhere: forest = on track to book, rust = needs a response, gold = warm,
// inkSoft = winding down. The token (which state/kind gets which) is decided and tested in the domain.
extension ReminderAccent {
    var color: Color {
        switch self {
        case .onTrack: return OVColor.forest
        case .attention: return OVColor.rust
        case .warm: return OVColor.gold
        case .neutral: return OVColor.inkSoft
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
