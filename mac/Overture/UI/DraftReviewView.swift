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
    // #367: request a re-prep on a prospect that already has a draft.
    var onReprep: (_ mode: ReprepMode) -> Void = { _ in }
    let onSaveDraft: (_ subject: String, _ body: String) -> Void
    // #2010: Dan's own opening for one contact. Optional so every existing construction site is
    // unaffected; without it the opening is shown but not editable.
    var onSaveOpening: ((_ recipientId: String, _ opening: String) -> Void)? = nil
    var onSetLostReason: (String) -> Void = { _ in }
    var onSend: () -> Void = {}
    // #718: Dan's deliberate override of the #407 salutation-review send block, confirmed via a
    // two-step alert (showOverrideConfirm below) rather than firing on a single tap.
    var onOverrideSalutationReview: () -> Void = {}
    // #789: Dan's confirmed override of the draft-lint send block, same two-step alert shape.
    var onOverrideDraftLint: () -> Void = {}
    var onDismissReply: () -> Void = {}
    // #1630: the copy-then-confirm control for a show reachable only through the act's own form.
    var onBeginFormPitch: (_ recipientId: String, _ formURL: String) -> Void = { _, _ in }
    var onRecordFormPitch: (_ recipientId: String) -> Void = { _ in }
    var onCancelFormPitch: (_ recipientId: String) -> Void = { _ in }
    // Per-contact manual-judge marking (#418 B1/B2): resolution nil + bounced false = "In conversation".
    var onMarkContact: (_ recipientId: String, _ resolution: RecipientResolution?, _ bounced: Bool) -> Void = { _, _, _ in }
    // #769: Dan's answer to "was that this show, or the whole org?"
    var onSetOrgDoNotContact: (Bool) -> Void = { _ in }
    // Per-contact conversation state (#652): a distinct vocabulary from onMarkContact's terminal
    // outcomes, mirroring FollowUpsView's own set/confirm split.
    var onSetRecipientConversationState: (_ recipientId: String, _ state: ConversationState) -> Void = { _, _ in }
    var onConfirmRecipientConversationState: (_ recipientId: String) -> Void = { _ in }
    var onDismissContactReply: (_ recipientId: String) -> Void = { _ in }
    var onDismissContactBounce: (_ recipientId: String) -> Void = { _ in }
    // #388: Dan dismissing a specific heuristic "looks like the venue" guess as wrong.
    var onDismissVenueMatch: (_ recipientId: String) -> Void = { _ in }
    // #722: same, for a suspected press/media contact.
    var onDismissPressContactMatch: (_ recipientId: String) -> Void = { _ in }
    var onDismissDuplicateContactMatch: (_ recipientId: String) -> Void = { _ in }
    var onAddRecipient: (_ email: String, _ name: String?) -> Void = { _, _ in }
    var onRemoveRecipient: (_ recipientId: String) -> Void = { _ in }
    // AI reply drafter (#420 C6 / #421): request a draft, send it on the contact's thread, or copy it out.
    var onDraftReply: (_ recipientId: String) -> Void = { _ in }
    var onSendReply: (_ recipientId: String) -> Void = { _ in }
    var onCopyReply: (_ recipientId: String) -> Void = { _ in }
    var onEditReplyDraft: (_ recipientId: String, _ body: String) -> Void = { _, _ in }
    // #1038: stop the detached reply-classify + drafter run that is drafting this reply. The run drafts
    // every queued reply in one detached pass, so this stops the whole run cooperatively (the runner sees
    // the sentinel on its next heartbeat tick), not just this one recipient's draft.
    var onCancelReplyDraft: () -> Void = {}
    var gmailConnected: Bool = false
    // #436: when this outbound draft is mid-send, the instant it was launched (nil = not sending), so the
    // Send button is replaced by a live "Sending… m:ss" indicator that flips to "looks stuck" past the
    // send timeout. #468: a retry IS safe here (unlike when this comment was written): both sendOne and
    // sendReplyDraft below now claim a persisted "in flight" field before their network await, so a
    // second call while the first is still live is refused rather than reaching the network again. No
    // heartbeat check on either LiveRunLabel, unlike the reply-draft one further down: this is an
    // in-process network await with no external heartbeat to check, so since + timeout is all there is.
    var outboundSendSince: Date? = nil
    // Same, keyed per recipient for an in-flight reply send.
    var replySendSince: (_ recipientId: String) -> Date? = { _ in nil }
    // #685: which contact, if any, a deep link (Reached Out row / Follow-ups sheet) targeted, so
    // that one row is gold-highlighted instead of just the whole card.
    var highlightedRecipientId: String? = nil
    // #1157: the styled sign-off is appended at SEND time (GmailMessage.rfc822), so the card used to
    // show the body WITHOUT it, and Dan approved an email without seeing the closing the recipient
    // actually gets. Preview the outgoing message's plain-text body (body + sign-off) using the SAME
    // composition the send path uses (GmailMessage.previewBody), so what he approves is what goes out.
    // Sourced from the stored Gmail signature; falls back to the plain sign-off when none is fetched yet.
    var outboundSignature: OutboundSignature = GmailSignatureStore.currentSignature()

    @State private var editing = false
    // #2010: in-progress edits to each contact's opening, keyed by recipient id. Cleared on save and on
    // cancel, so a half-typed opening never survives into the next draft Dan opens.
    @State private var openingEdits: [String: String] = [:]
    @State private var askAboutWholeOrg = false   // #769
    @State private var draftSubject = ""
    @State private var draftBody = ""
    @State private var editingReplyFor: String?    // recipient id whose reply draft is being edited (#423 E)
    @State private var replyEditText = ""
    @State private var lostReason = ""
    // #1418: the value last written to the store, so a commit on focus loss with no edit writes nothing.
    @State private var lastSavedLostReason = ""
    @FocusState private var lostReasonFocused: Bool
    @State private var showAddContact = false
    @State private var addContactEmail = ""
    @State private var addContactName = ""
    @State private var showOverrideConfirm = false
    @State private var showLintOverrideConfirm = false

    // #885: the sentence lives in DraftCheck, which is the type that decides what blocks a send.
    private var draftLintBlockMessage: String {
        DraftCheck.blockMessage(blockers: item.draftLintBlockers)
    }
    // #733: guard against repeatedly re-prepping the same prospect.
    @State private var showReprepCooldownConfirm = false
    @State private var pendingReprepMode: ReprepMode?

    private var isApproved: Bool { item.status == .approved }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            contactLine
            venueMatchWarnings
            pressContactWarnings
            duplicateContactWarnings
            draftBlock
            performerOverridePreviews
            actionRow
            conversationContactsSection
            if item.isLost { lostReasonField }
        }
        .padding(OVSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OVColor.surfaceSunk.opacity(0.5))
        )
        // #769: "Not interested" is genuinely ambiguous, and the two readings have wildly different
        // consequences: one closes a show, the other means never email these people again. Guessing
        // either way is wrong (silently burn an org who only meant this show, or keep pitching one who
        // asked you to stop). So ask, once, in the moment Dan has actually read the reply.
        //
        // The default is the SAFE, reversible reading: it takes a deliberate second click to mark a
        // whole org, and the destructive role makes that click feel like what it is.
        .confirmationDialog("Did they mean this show, or the whole organisation?",
                            isPresented: $askAboutWholeOrg, titleVisibility: .visible) {
            Button("Just this show") { }
            Button(DraftReviewNotes.neverContactOrg(groupName: item.groupName), role: .destructive) {
                onSetOrgDoNotContact(true)
            }
        } message: {
            Text("If they asked you to stop emailing them, Overture will keep every future show from this org out of your queue. You can undo it from the row.")
        }
    }

    @ViewBuilder private var contactLine: some View {
        let primary = item.primaryContact
        let display = ContactDisplay.from(name: primary?.name, role: primary?.role,
                                          email: primary?.email, formURL: primary?.contactFormURL)
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
            if let conf = primary?.contactConfidence {
                ConfidencePip(confidence: conf, sourceURL: primary?.contactSourceLinkURL)
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

    // #388/#722: contactLine only ever shows the ONE primary contact, so a flagged SECONDARY
    // contact (e.g. a presenter) would otherwise be invisible before send. Lists every contact
    // currently flagged, not just the primary. Dismissible (a code guess, weaker than the
    // runbook's own STRICT rules for the AI), unlike the AI's own absolute disqualification.
    @ViewBuilder
    private func recipientWarning(_ contacts: [RecipientSnapshot], message: @escaping (RecipientSnapshot) -> String,
                                  dismissLabel: String, onDismiss: @escaping (String) -> Void) -> some View {
        ForEach(contacts) { c in
            HStack(spacing: OVSpacing.xs) {
                Text(message(c)).font(.system(size: 10)).foregroundStyle(OVColor.rust).lineLimit(1)
                Button(dismissLabel) { onDismiss(c.id) }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(OVColor.inkSoft)
            }
        }
    }

    @ViewBuilder private var venueMatchWarnings: some View {
        recipientWarning(item.contacts.filter { $0.looksLikeVenue && !$0.looksLikeVenueDismissed },
                        message: { DraftReviewNotes.venueSuspect(name: $0.displayName) },
                        dismissLabel: "Not the venue", onDismiss: onDismissVenueMatch)
    }

    // #722: same shape as venueMatchWarnings above, for the runbook's separate press/media rule.
    @ViewBuilder private var pressContactWarnings: some View {
        recipientWarning(item.contacts.filter { $0.looksLikePressContact && !$0.looksLikePressContactDismissed },
                        message: { DraftReviewNotes.pressSuspect(name: $0.displayName) },
                        dismissLabel: "Not press/media", onDismiss: onDismissPressContactMatch)
    }

    // #726: same shape as venueMatchWarnings/pressContactWarnings above, for a contact already
    // pitched on another still-open prospect for what looks like the same real-world performance.
    @ViewBuilder private var duplicateContactWarnings: some View {
        recipientWarning(item.contacts.filter { $0.looksLikeDuplicateContact && !$0.looksLikeDuplicateContactDismissed },
                        message: { DraftReviewNotes.duplicateSuspect(name: $0.displayName) },
                        dismissLabel: "Not a duplicate", onDismiss: onDismissDuplicateContactMatch)
    }

    // #2010: the top of the email, on screen. Dan's rule (2026-08-03): "I want whatever is in the text
    // box that I see to be what's sent. There should never be any hidden addition that I cannot see in
    // the app." This used to be composed at send and appear nowhere, so a draft he read and approved was
    // not the string that went out.
    //
    // One line per CONTACT, because each is addressed differently and a show can have more than one. That
    // is also what makes editing safe: his words on how he would use it were "if it's multiple i just
    // don't touch it but if it's single and I want to update it I can", and a per-contact field means an
    // edit can never re-address somebody else by the wrong name.
    @ViewBuilder private func openingBlock(editable: Bool) -> some View {
        if !item.contacts.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(item.contacts) { c in
                    if editable, onSaveOpening != nil {
                        HStack(spacing: OVSpacing.xs) {
                            TextField("Opening", text: Binding(
                                get: { openingEdits[c.id] ?? c.outgoingOpening },
                                set: { openingEdits[c.id] = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .font(OVType.body)
                            if item.contacts.count > 1 {
                                Text(c.displayName).font(OVType.tag).foregroundStyle(OVColor.inkFaint)
                            }
                        }
                    } else {
                        HStack(spacing: OVSpacing.xs) {
                            Text(c.outgoingOpening)
                                .font(OVType.body).foregroundStyle(OVColor.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            if c.openingIsCustom {
                                Text("Yours").font(OVType.tag).foregroundStyle(OVColor.gold)
                            }
                            if item.contacts.count > 1 {
                                Text(c.displayName).font(OVType.tag).foregroundStyle(OVColor.inkFaint)
                            }
                        }
                    }
                }
                // The one thing worth pointing at rather than silently fixing: the body greets as well,
                // so the email says hello twice. Said, never rewritten and never blocked, because he can
                // now see both halves at once and it is his text.
                if DraftOpeningNotice.bodyRepeatsAGreeting(item.draftBody) {
                    Text(DraftOpeningNotice.note)
                        .font(OVType.meta).foregroundStyle(OVColor.rust)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var draftBlock: some View {
        if editing {
            VStack(alignment: .leading, spacing: OVSpacing.xs) {
                TextField("Subject", text: $draftSubject)
                    .textFieldStyle(.roundedBorder)
                openingBlock(editable: true)
                TextEditor(text: $draftBody)
                    .font(OVType.body)
                    .frame(minHeight: 120)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(OVColor.line))
                HStack {
                    Button("Save") {
                        // #2010: the opening is part of the email, so it saves with it.
                        for (id, text) in openingEdits { onSaveOpening?(id, text) }
                        openingEdits = [:]
                        onSaveDraft(draftSubject, draftBody)
                        editing = false
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Cancel") { openingEdits = [:]; editing = false }
                        .buttonStyle(.plain).foregroundStyle(OVColor.inkSoft)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if let subject = item.draftSubject {
                    Text(subject).font(.system(size: 13, weight: .semibold)).foregroundStyle(OVColor.ink)
                }
                openingBlock(editable: false)
                if let body = item.draftBody {
                    // #1157/#1203: show the body WITH the sign-off the send path appends, so Dan approves
                    // the real outgoing message. DraftSignaturePreview renders the styled text/html a rich
                    // mail client shows (via GmailMessage.previewHTML, the SAME composition the send path
                    // embeds, so the card can't drift from the wire), falling back to the plain-text
                    // previewBody when there is no HTML signature or the render fails.
                    DraftSignaturePreview(draftBody: body, signature: outboundSignature)
                }
                // #846: Dan's call (2026-07-13) that these stay SEPARATE tags. Both facts are true at
                // once on a draft he edited: he edited it, AND a model wrote the text he edited (which
                // PrepImporter deliberately preserves). The trace is the quieter of the two, so it reads
                // as provenance rather than as a claim about his edit.
                HStack(spacing: 6) {
                    if item.draftEditedByDan {
                        Text("Edited").font(.system(size: 10)).foregroundStyle(OVColor.gold)
                    }
                    if let trace = item.draftTraceLabel {
                        Text(trace).font(.system(size: 10)).foregroundStyle(OVColor.inkFaint)
                    }
                }
                // #367: a re-prep still awaiting the next Prep run, distinct from "Edited" (this
                // just means a run is pending, not that Dan has touched the text).
                if item.isReprepQueued {
                    Text("Re-prep queued").font(.system(size: 10)).foregroundStyle(OVColor.gold)
                }
                draftCheckFlags
            }
        }
    }

    // Self-check findings (#11): voice / AI-tells / stance issues in the draft, surfaced so
    // Dan's review is judgment, not cleanup. Only on an unedited draft from the run: once
    // Dan edits it, it's his.
    @ViewBuilder private var draftCheckFlags: some View {
        // #789: the BLOCKING findings show whatever the draft's provenance. The advisory ones below
        // are about voice, and once Dan edits the text the voice is his; but a dead link or an
        // unfilled placeholder is a fact about the words a stranger will read, no matter who typed
        // them, so his own edit gets flagged too (and it is what actually holds the send).
        // #843: except once approved-and-blocked, when the "This draft won't send: …" gate by the Send
        // button already names the same reason. The decision is DraftReviewNotes', tested, not this view's.
        if DraftReviewNotes.showsBlockingFlagsNearBody(isApproved: isApproved,
                                                       lintBlocked: item.draftLintBlocked) {
            issueFlags(item.draftLintBlockers)
        }
        if !item.draftEditedByDan, let body = item.draftBody {
            issueFlags(DraftCheck.findings(in: body,
                                           title: item.groupName,   // #1141: don't flag the title's own "!"
                                           knownsDate: item.performanceDate != nil,
                                           knownsVenue: item.venue != nil)
                .filter { !$0.isBlocking })
        }
    }

    // #642 (#634 Phase D): a directly-addressed performer's own draft, shown BEFORE Dan approves or
    // sends, not just after (the per-recipient conversationContactsSection below only appears once
    // isSent). Read-only for now; editing an override is deferred to a later phase.
    @ViewBuilder private var performerOverridePreviews: some View {
        ForEach(item.contacts.filter { $0.overrideBody?.isEmpty == false }) { c in
            VStack(alignment: .leading, spacing: 2) {
                Text(DraftReviewNotes.willInsteadReceive(name: c.displayName))
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

                // #792: "Sent" was the whole of it, and a contact held back by a review guard is not
                // sendable, so the show read as fully done while that person never received anything.
                // The held contact is usually the one worth emailing (the act's own address, held by a
                // heuristic Dan need only glance at), so both facts are said at once: it went, AND
                // somebody is still waiting on him.
                if let held = DraftReviewNotes.heldContacts(item.blockedContactCount) {
                    Label(held, systemImage: "exclamationmark.triangle")
                        .font(OVType.meta).foregroundStyle(OVColor.gold)
                        .help("A contact on this show is held back by a check (a venue guess, a press address, a duplicate, the salutation, or the draft lint). Look at it below: dismissing the check releases the email.")
                }
                Spacer()
                if item.isAutoReplied {
                    Button("Not a real reply") { onDismissReply() }
                        .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                        .help("This was not a genuine reply (an auto-reply or out of office). Revert it; a new reply will still flag.")
                }
                derivedStatusLabel
            } else if isApproved {
                if let since = outboundSendSince {
                    LiveRunLabel(base: "Sending", since: since, timeout: RunTimeouts.send,
                                 font: OVType.meta, color: OVColor.inkSoft, onRetry: { onSend() })
                } else {
                    Button { onSend() } label: {
                        Label("Send", systemImage: "paperplane")
                            .font(OVType.meta).foregroundStyle(OVColor.onForest)
                            .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                            .background(Capsule().fill(OVColor.forest))
                    }
                    .buttonStyle(.plain)
                    .disabled(!gmailConnected || !item.hasPendingRecipient)
                    .help(GmailCopy.sendHelp(connected: gmailConnected, whenConnected: "Send this email now"))
                    Button("Unapprove") { onUnapprove() }
                        .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    reprepControl
                    // #1311: an approved show with no emailable contact can never send, and the greyed
                    // Send button never said why. This explains the stall so Dan can add a contact. The
                    // wording is DraftReviewNotes' (#885); the view only decides where it sits.
                    if let note = DraftReviewNotes.noSendableEmail(isApproved: isApproved,
                                                                   hasPendingRecipient: item.hasPendingRecipient,
                                                                   hasAnyEmailContact: item.hasAnyEmailContact) {
                        Text(note)
                            .font(.system(size: 10)).foregroundStyle(OVColor.rust).lineLimit(1)
                    }
                    // #407: a plain, mostly non-dismissible warning, not a flag Dan can dismiss as
                    // wrong. It's a fact about the stored text, and clears itself once the draft is
                    // fixed. #718: he CAN override the block itself via a deliberate two-step confirm
                    // (a native alert, not a single tap), which then tones the message down rather
                    // than hiding it, so there's still a visible trail the send happened despite it.
                    // #885: the wording is DraftReviewNotes'; the view only decides whether the
                    // Override button belongs beside it.
                    if let note = DraftReviewNotes.salutation(needsReview: item.draftNeedsSalutationReview,
                                                              overridden: item.salutationReviewOverridden) {
                        Text(note)
                            .font(.system(size: 10)).foregroundStyle(OVColor.rust).lineLimit(1)
                        if !item.salutationReviewOverridden {
                            Button("Override") { showOverrideConfirm = true }
                                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(OVColor.inkSoft)
                        }
                    }
                    // #789: same shape as the salutation block above. A fact about the words, not a
                    // guess Dan can dismiss as wrong: it clears itself the moment the text is fixed.
                    // He can still override it, but only through a deliberate two-step confirm, and
                    // the message afterwards tones down rather than disappearing, so there is a
                    // visible trail that the send happened despite it.
                    if let note = DraftReviewNotes.lint(blocked: item.draftLintBlocked,
                                                        blockers: item.draftLintBlockers) {
                        Text(note)
                            .font(.system(size: 10)).foregroundStyle(OVColor.rust).lineLimit(1)
                        if item.draftLintBlocked {
                            Button("Override") { showLintOverrideConfirm = true }
                                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(OVColor.inkSoft)
                        }
                    }
                    if let line = SendFailureLine.text(for: item.sendError) {
                        Text(line).font(.system(size: 10)).foregroundStyle(OVColor.rust).lineLimit(1)
                    }
                }
                Spacer()
            } else if case let .ready(recipientId, formURL) = item.formPitch {
                // #1630: this show has no address at all, so Approve is permanently disabled and there is
                // no other way forward. Dan pitches it by hand; this is the only control that matters here.
                Button { onBeginFormPitch(recipientId, formURL) } label: {
                    Label(FormOutreachCopy.copyAndOpen, systemImage: "doc.on.clipboard")
                        .font(OVType.meta).foregroundStyle(OVColor.onForest)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                        .background(Capsule().fill(OVColor.forest))
                }
                .buttonStyle(.plain)
                // Says only what the button does not: nothing is recorded until he confirms.
                .help("Nothing is recorded until you confirm you sent it.")
                Button("Edit") {
                    draftSubject = item.draftSubject ?? ""
                    draftBody = item.draftBody ?? ""
                    editing = true
                }
                .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                Button("Skip") { onSkip() }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                // #1828: this is the card that needs Re-prep MOST. The show has no address at all, so
                // "find contacts only" is the highest-value action available on it, and it was the one
                // branch that never drew the control.
                reprepControl
                Spacer()
            } else if case let .awaitingConfirmation(recipientId, _, startedAt) = item.formPitch {
                Text(FormOutreachCopy.awaitingQuestion(startedAt: startedAt, now: Date()))
                    .font(OVType.meta).foregroundStyle(OVColor.ink)
                // #1828, Dan's call: offered here too. A show waiting on his answer is still a show whose
                // contacts he may want researched, and the answer controls below are untouched by it.
                reprepControl
                Button { onRecordFormPitch(recipientId) } label: {
                    Text(FormOutreachCopy.sentIt).font(OVType.meta).foregroundStyle(OVColor.onForest)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                        .background(Capsule().fill(OVColor.forest))
                }
                .buttonStyle(.plain)
                Button(FormOutreachCopy.didNotSend) { onCancelFormPitch(recipientId) }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                Spacer()
            } else {
                Button { onApprove() } label: {
                    Text("Approve").font(OVType.meta).foregroundStyle(OVColor.onForest)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                        .background(Capsule().fill(OVColor.forest))
                }
                .buttonStyle(.plain)
                // #399: hasPendingRecipient means "at least one recipient still pending with a real
                // address", exactly what this gate needs.
                .disabled(!item.hasPendingRecipient)
                Button("Edit") {
                    draftSubject = item.draftSubject ?? ""
                    draftBody = item.draftBody ?? ""
                    editing = true
                }
                .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                Button("Skip") { onSkip() }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                reprepControl
            }
            if !isApproved { Spacer() }
        }
        .alert("Send anyway?", isPresented: $showOverrideConfirm) {
            Button("Send Anyway") { onOverrideSalutationReview() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Overture couldn't safely confirm the greeting in this draft is free of a real name. Confirm you've checked it and it's fine to send as-is.")
        }
        // #789: the draft lint's own override, deliberately a separate confirm from the greeting one
        // above, so the reason Dan is waving something through is never ambiguous.
        .alert("Send anyway?", isPresented: $showLintOverrideConfirm) {
            Button("Send Anyway") { onOverrideDraftLint() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DraftReviewNotes.lintOverrideConfirm(blockers: item.draftLintBlockers))
        }
        // #733: guard against repeatedly re-prepping the same prospect.
        .alert("Redo this re-prep?", isPresented: $showReprepCooldownConfirm) {
            Button("Redo Anyway") {
                if let mode = pendingReprepMode { onReprep(mode) }
                pendingReprepMode = nil
            }
            Button("Cancel", role: .cancel) { pendingReprepMode = nil }
        } message: {
            Text(ReprepRequest.confirmMessage(lastServedAt: item.reprepLastServedAt, now: Date()))
        }
    }

    // #367: one button, opens a picker of the three re-prep choices, rather than separate buttons
    // for each. The draft-affecting choices are disabled once anything has actually been sent for
    // this prospect (a partial send on a multi-recipient show still leaves it .approved); finding
    // new contacts never touches text someone already received, so it stays available regardless.
    // #733: the whole menu disables while a request is already pending (nothing new to pick), and
    // any choice made within the cooldown window confirms before actually asking, rather than
    // silently spending another Prep run on a prospect just researched.
    // #1828: Re-prep, drawn from ONE decision (QueueModel.reprepOffer) rather than an `if` repeated in
    // each action branch, which is how the branch that needed it most ended up without it. The blocked
    // state is drawn, not hidden: a control that vanishes teaches nothing, and this is a state Dan can
    // clear himself by accepting the clash on the show.
    @ViewBuilder private var reprepControl: some View {
        switch QueueModel.reprepOffer(for: item) {
        case .shown:
            reprepMenu
        case .blocked(let reason):
            reprepMenu.disabled(true).help(reason)
        case .hidden:
            EmptyView()
        }
    }

    private var reprepMenu: some View {
        Menu("Re-prep") {
            Button("Redraft only") { requestReprep(.draftOnly) }
                .disabled(item.isSent)
            Button("Find contacts only") { requestReprep(.contactsOnly) }
            Button("Redraft and find contacts") { requestReprep(.both) }
                .disabled(item.isSent)
        }
        .disabled(item.isReprepQueued)
        .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
    }

    private func requestReprep(_ mode: ReprepMode) {
        if ReprepRequest.isInCooldown(lastServedAt: item.reprepLastServedAt, now: Date()) {
            pendingReprepMode = mode
            showReprepCooldownConfirm = true
        } else {
            onReprep(mode)
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
        let highlighted = highlightedRecipientId == c.id
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: OVSpacing.xs) {
                // #1137: no provenance tag ("act"/"performer"/"presenter"/"added") here: it repeats what
                // the contact summary above already tells Dan. And the leading glyph does double duty: for
                // a still-pending contact it IS the remove control (see leadingGlyph), so there's no
                // separate "Remove" row below.
                leadingGlyph(for: c)
                Text(c.displayName).fontWeight(.medium).foregroundStyle(OVColor.ink)
                // #2015: the ADDRESS, always, not only when there is no name to show instead. Dan's rule
                // (2026-08-03): "It should show me every email it's going to send to". A row reading
                // "Sarah Chen" does not tell him which of her addresses is about to be used, and on a show
                // that already carried a found contact it may not be hers at all.
                if let email = c.email, !email.isEmpty, email != c.displayName {
                    Text(email).font(OVType.meta).foregroundStyle(OVColor.inkSoft).lineLimit(1)
                        .truncationMode(.middle)
                }
                // Which one the next Send actually goes to. The order behind it is a real judgment and
                // stays (#366/#368, pitch the act, the presenter only after); what changes is that it is
                // no longer invisible.
                if c.id == item.nextRecipientId {
                    Text("Sending to this one").font(OVType.tag).foregroundStyle(OVColor.gold)
                }
                // On the show but NOT going to be emailed, so the list does not overstate itself.
                if c.isHeldFromSending {
                    Text("Held, not sending").font(OVType.tag).foregroundStyle(OVColor.rust)
                }
                Spacer()
                // #656: a soft/temporary Gmail delay, purely informational, alongside (never in
                // place of) the status line, since it must never affect isSilent/eligibility.
                if c.hasRecentDeliveryDelay(now: Date()) {
                    Text("Delivery delayed").font(OVType.tag).foregroundStyle(OVColor.gold)
                }
                Text(c.statusLabel).font(OVType.meta).foregroundStyle(contactStatusColor(c))
            }
            .font(.system(size: 12))
            // #642 (#634 Phase D): a performer's direct-address draft, shown read-only so Dan can see
            // exactly what THIS contact will receive instead of the shared (third-person) draft above.
            // Editing this override is not built yet (deferred to a later phase).
            if let overrideBody = c.overrideBody, !overrideBody.isEmpty {
                Text(DraftReviewNotes.willReceive(body: overrideBody))
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
            // #1740: the stand-down has to be visible somewhere Dan looks, or the only trace of his
            // decision is a row that stopped appearing in Due.
            if let line = StandDownCopy.standDownLine(stoodDownAt: c.outreachStoodDownAt, now: Date()) {
                Text(line).font(OVType.meta).foregroundStyle(OVColor.inkSoft).padding(.leading, 20)
            }
            if c.sendState == .sent {
                HStack(spacing: OVSpacing.xs) {
                    Menu {
                        Button("In conversation") { onMarkContact(c.id, nil, false) }
                        Button("Booked") { onMarkContact(c.id, .booked, false) }
                        Button("Closed (not now)") { onMarkContact(c.id, .declinedSoft, false) }
                        Button("Closed (not interested)") {
                            onMarkContact(c.id, .declinedHard, false)
                            // #769: "not interested" is ambiguous, and the two readings have wildly
                            // different consequences. Ask once, here, in the moment Dan has actually
                            // read the reply, rather than guessing or relying on him to remember an
                            // org-level action later, which is exactly when he won't.
                            askAboutWholeOrg = true
                        }
                        Button("Bounced") { onMarkContact(c.id, nil, true) }
                        Divider()
                        // #399: distinct from every option above, none of which mean "stop pursuing
                        // without recording an outcome".
                        Button("Remove", role: .destructive) { onRemoveRecipient(c.id) }
                    } label: {
                        // #1139: this menu records an OUTCOME. Its outcome flag icon and forest accent
                        // (both from ContactRowControls.Kind.outcome, tested) mark it as a different KIND
                        // of control from the conversation-state menu beside it, so the two no longer read
                        // as duplicates and the colour difference is deliberate, not incidental.
                        Label("Mark…", systemImage: ContactRowControls.Kind.outcome.icon)
                            .font(OVType.meta).foregroundStyle(ContactRowControls.Kind.outcome.accent.color)
                            .padding(.horizontal, OVSpacing.sm).padding(.vertical, 4)
                            .background(Capsule().strokeBorder(ContactRowControls.Kind.outcome.accent.color.opacity(0.4), lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    stateControl(for: c)
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
            }
            // #1137: a still-pending contact no longer gets its own indented "Remove" row. Its leading
            // glyph is the X that removes it (leadingGlyph / #399: Prospect.removeOrSuppressRecipient
            // hard-deletes a still-pending row).
            if c.replied { replyDraftBlock(c) }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, OVSpacing.sm)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(highlighted ? OVColor.gold.opacity(0.25) : OVColor.surface.opacity(0.6)))
        .id(c.id)
    }

    // The AI reply drafter surface for one replied contact (#420 C6 / #421): a non-binding intent hint,
    // and either the drafted reply (send on the thread / copy out), a "drafting…" progress, or a button
    // to request a draft. Treated as request-response even though the run is detached.
    @ViewBuilder private func replyDraftBlock(_ c: RecipientSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let hint = c.intentHint, !hint.isEmpty {
                Text(QueueModel.aiReadNote(hint: hint))
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
                // #846: same two separate tags as the cold draft above, for the same reason. A reply goes
                // to somebody who already wrote back to him, so it is the LAST place the trace should be
                // missing (#874).
                HStack(spacing: 6) {
                    if c.replyDraftEditedByDan {
                        Text("Edited").font(.system(size: 10)).foregroundStyle(OVColor.gold)
                    }
                    if let trace = c.replyDraftTraceLabel {
                        Text(trace).font(.system(size: 10)).foregroundStyle(OVColor.inkFaint)
                    }
                }
                // #456 / #459: flag a reply draft that asks for the date/venue this show already carries,
                // same as the cold path, but suppressed once Dan edits (logic in replyDraftFindings).
                issueFlags(c.replyDraftFindings(title: item.groupName,   // #1141: don't flag the title's own "!"
                                                knownsDate: item.performanceDate != nil,
                                                knownsVenue: item.venue != nil))
                if let since = replySendSince(c.id) {
                    LiveRunLabel(base: "Sending reply", since: since, timeout: RunTimeouts.send,
                                 font: OVType.meta, color: OVColor.inkSoft, onRetry: { onSendReply(c.id) })
                } else {
                    HStack(spacing: OVSpacing.xs) {
                        Button { onSendReply(c.id) } label: {
                            Label("Send reply", systemImage: "paperplane")
                                .font(OVType.meta).foregroundStyle(OVColor.onForest)
                                .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                                .background(Capsule().fill(OVColor.forest))
                        }
                        .buttonStyle(.plain).disabled(!gmailConnected)
                        .help(GmailCopy.sendHelp(connected: gmailConnected, whenConnected: "Send this reply on the contact's thread"))
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
                // #1038: a Cancel beside it stops the detached run cooperatively, so Dan can abandon a
                // drafting run he no longer wants instead of only waiting it out.
                HStack(spacing: OVSpacing.xs) {
                    // #1085: the run's "N of M" count is a single run-wide fact, so it lives once at the
                    // top of the queue (QueueView.replyRunLine), not repeated on every recipient this run
                    // is currently drafting. This per-recipient label keeps its own genuinely per-recipient
                    // states: spinner + elapsed (working), a stall timeout that flips to Retry, and the
                    // run's real heartbeat, so "working / still-alive / stalled" stay distinguishable here.
                    LiveRunLabel(base: "Drafting a reply", since: c.replyDraftRequestedAt,
                                 timeout: RunTimeouts.replyDraft,
                                 font: OVType.meta, color: OVColor.inkSoft,
                                 onRetry: { onDraftReply(c.id) },
                                 heartbeat: { ReplyClassifyService.heartbeat(now: Date()) })
                    Button("Cancel") { onCancelReplyDraft() }
                        .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.rust)
                        .help("Stop the reply drafting run")
                }
            } else {
                Button("Draft a reply") { onDraftReply(c.id) }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.forest)
                    .padding(.horizontal, OVSpacing.sm).padding(.vertical, 4)
                    .background(Capsule().strokeBorder(OVColor.forest.opacity(0.4), lineWidth: 1))
            }
        }
        .padding(.leading, 20)
    }

    // #1137: for a still-pending contact the leading glyph IS the remove control (the X sits exactly
    // where the person icon used to be, so a click there removes the contact), which is why the separate
    // "Remove" row is gone. A sent contact keeps a plain, non-interactive person icon (it can't be
    // hard-deleted; its removal is the destructive item inside the "Mark…" menu). The which-and-whether
    // rule lives in ContactRowControls, tested, not in this view body.
    @ViewBuilder private func leadingGlyph(for c: RecipientSnapshot) -> some View {
        let icon = Image(systemName: ContactRowControls.leadingIcon(sendState: c.sendState))
            .foregroundStyle(OVColor.inkFaint)
        if ContactRowControls.leadingIsRemove(sendState: c.sendState) {
            Button { onRemoveRecipient(c.id) } label: { icon }
                .buttonStyle(.plain)
                .help("Remove this contact")
        } else {
            icon
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

    // Where THIS CONTACT's conversation stands once they've replied (#111/#652): Dan tags it so the
    // right event-aware reminder fires. A distinct control from the "Mark…" menu beside it (a
    // different vocabulary: terminal outcomes there, in-flight conversation state here), mirroring
    // FollowUpsView's own set/confirm split for the same per-recipient state.
    private func stateControl(for c: RecipientSnapshot) -> some View {
        // #1139: this control sets the in-flight CONVERSATION STATE, a different kind of thing from the
        // "Mark…" outcome menu beside it. Its conversation icon and gold accent (from
        // ContactRowControls.Kind.conversationState, tested) pair with, but stay clearly distinct from,
        // the outcome menu's flag + forest, so the two read as a deliberate system rather than duplicates.
        ConversationStateControl(currentState: c.conversationState, stateSource: c.conversationStateSource,
                                 systemImage: ContactRowControls.Kind.conversationState.icon,
                                 accent: ContactRowControls.Kind.conversationState.accent.color,
                                 onSet: { onSetRecipientConversationState(c.id, $0) },
                                 onConfirm: { onConfirmRecipientConversationState(c.id) })
    }

    // Always visible once Dan marks a lead lost: an optional note for his own reference
    // (it doesn't change the ranking, which is driven by the soft/hard choice).
    private var lostReasonField: some View {
        HStack(spacing: OVSpacing.xs) {
            Image(systemName: "text.bubble")
                .font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
            TextField("Why lost? (optional note)", text: $lostReason)
                .textFieldStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.ink)
                .focused($lostReasonFocused)
                // #1418: commit once, on submit and on focus loss, not on every keystroke. A twelve-character
                // note used to be twelve full setLostReason + SwiftData saves.
                .onSubmit { commitLostReason() }
                .onChange(of: lostReasonFocused) { _, focused in
                    if !focused { commitLostReason() }
                }
        }
        .padding(.horizontal, OVSpacing.xs).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(OVColor.surfaceSunk.opacity(0.5)))
        .onAppear {
            lostReason = item.lostReason ?? ""
            lastSavedLostReason = lostReason
        }
    }

    // #1418: save the note only when it changed since the last write, so submitting or leaving an untouched
    // field is a no-op rather than a redundant store write. The changed-guard is LostReasonCommit (tested).
    private func commitLostReason() {
        guard LostReasonCommit.shouldSave(current: lostReason, lastSaved: lastSavedLostReason) else { return }
        onSetLostReason(lostReason)
        lastSavedLostReason = lostReason
    }

    private var derivedStatusColor: Color {
        switch item.performanceStatus {
        case .booked: return OVColor.forest
        case .active: return OVColor.gold
        case .lostDoorOpen: return OVColor.inkSoft
        // #1840: quiet, like the door-open close. It is a decision Dan made, not a setback to flag at him.
        case .stoodDown: return OVColor.inkSoft
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
    var emma = RecipientSnapshot(id: "emma@aurorastrings.example", name: "Emma Robinson",
                                 email: "emma@aurorastrings.example", role: "Marketing & Communications Manager",
                                 provenance: .act, sendState: .sent, replied: true, lastReplyText: nil,
                                 resolution: nil, bounced: false, outcomeSource: .manual)
    emma.contactConfidence = .high
    emma.conversationState = .wantsToBook
    emma.conversationStateSource = .manual
    item.contacts = [emma]
    item.draftSubject = "Photographing Aurora Strings at Carnegie Hall."
    item.draftBody = "Hi Emma, I photograph performing arts in New York and saw Aurora Strings is at Carnegie Hall. I shoot unobtrusive, no-flash documentary coverage and think it would suit this program."
    item.sentAt = Date()
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
    // #363: when set (only ever at confidence == .high, per RecipientSnapshot.contactSourceLinkURL),
    // the badge becomes a clickable link to the page the contact was verified on.
    let sourceURL: URL?
    var body: some View {
        // #885: the WORDS come from the enum (ContactConfidence.label); only the colour is the view's.
        let label = confidence.label
        let color: Color = {
            switch confidence {
            case .high: return OVColor.forest
            case .medium: return OVColor.gold
            case .low: return OVColor.rust
            }
        }()
        let pip = Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
        if let sourceURL {
            Link(destination: sourceURL) { pip }
        } else {
            pip
        }
    }
}
