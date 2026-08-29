import SwiftUI

// The Trigger-2 review surface, shown inside a row once the Prep run has found a
// contact and drafted an email. Dan reads the contact (with its confidence), edits
// the draft inline if he likes, then sends or skips. #2050: one button carries it
// from here to sent, through the confirmation sheet that shows the whole email and
// everyone it reaches; approving is the first half of that press, not a step of its
// own on a screen of its own.
struct DraftReviewView: View {
    let item: QueueItem
    let onUnapprove: () -> Void
    // #367: request a re-prep on a prospect that already has a draft.
    var onReprep: (_ mode: ReprepMode) -> Void = { _ in }
    let onSaveDraft: (_ subject: String, _ body: String) -> Void
    // #2034: Dan's per-event choice between one shared email and one each.
    var onSetSendsTogether: ((_ together: Bool) -> Void)? = nil
    var onSetLostReason: (String) -> Void = { _ in }
    var onSend: () -> Void = {}
    // #2545: Dan's deliberate override of the greeting send block, confirmed via a two-step alert
    // (showGreetingOverrideConfirm below) rather than firing on a single tap.
    var onOverrideGreeting: () -> Void = {}
    // #789: Dan's confirmed override of the draft-lint send block, same two-step alert shape.
    var onOverrideDraftLint: () -> Void = {}
    var onDismissReply: () -> Void = {}
    // #1630: the copy-then-confirm control for a show reachable only through the act's own form.
    var onBeginFormPitch: (_ recipientId: String, _ formURL: String) -> Void = { _, _ in }
    var onRecordFormPitch: (_ recipientId: String) -> Void = { _ in }
    var onCancelFormPitch: (_ recipientId: String) -> Void = { _ in }
    // Per-contact manual-judge marking (#418 B1/B2): resolution nil + bounced false = "In conversation".
    var onMarkContact: (_ recipientId: String, _ resolution: RecipientResolution?, _ bounced: Bool) -> Void = { _, _, _ in }
    // #2395: the show reached an ending. One callback for all five, because they are one vocabulary and
    // one write (ProspectMutations.recordOutcome), not five buttons each doing their own thing.
    var onRecordOutcome: (ShowOutcome) -> Void = { _ in }
    // #2395: Dan takes the ending back, so a mis-pressed close-out is reachable from the card he is on.
    var onReopenOutcome: () -> Void = {}
    // #769: Dan's answer to "was that this show, or the whole org?"
    var onSetOrgDoNotContact: (Bool) -> Void = { _ in }
    var onDismissContactReply: (_ recipientId: String) -> Void = { _ in }
    var onDismissContactBounce: (_ recipientId: String) -> Void = { _ in }
    // #388: Dan dismissing a specific heuristic "looks like the venue" guess as wrong.
    var onDismissVenueMatch: (_ recipientId: String) -> Void = { _ in }
    // #722: same, for a suspected press/media contact.
    var onDismissPressContactMatch: (_ recipientId: String) -> Void = { _ in }
    var onDismissDuplicateContactMatch: (_ recipientId: String) -> Void = { _ in }
    // #1866: same, for a confident find held down to unverified because it named no page.
    var onDismissConfidenceHeldDown: (_ recipientId: String) -> Void = { _ in }
    var onDismissAddressInAnotherName: (_ recipientId: String) -> Void = { _ in }
    var onAddRecipient: (_ email: String, _ name: String?) -> Void = { _, _ in }
    var onRemoveRecipient: (_ recipientId: String) -> Void = { _ in }
    // AI reply drafter (#420 C6 / #421): request a draft, send it on the contact's thread, or copy it out.
    var onDraftReply: (_ recipientId: String) -> Void = { _ in }
    var onSendReply: (_ recipientId: String) -> Void = { _ in }
    var onCopyReply: (_ recipientId: String) -> Void = { _ in }
    // #2869: step two of copy-then-confirm, threaded through so the card's button is a live one.
    var onConfirmCopiedReplySent: (_ recipientId: String) -> Void = { _ in }
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
    @State private var askAboutWholeOrg = false   // #769
    @State private var draftSubject = ""
    @State private var draftBody = ""
    @State private var lostReason = ""
    // #1418: the value last written to the store, so a commit on focus loss with no edit writes nothing.
    @State private var lastSavedLostReason = ""
    @FocusState private var lostReasonFocused: Bool
    @State private var showAddContact = false
    @State private var addContactEmail = ""
    @State private var addContactName = ""
    @State private var showGreetingOverrideConfirm = false
    @State private var showLintOverrideConfirm = false
    // #733: guard against repeatedly re-prepping the same prospect. #2007: and against replacing text
    // Dan wrote himself. Both raise this one alert, carrying whichever sentence applies.
    @State private var showReprepConfirm = false
    @State private var pendingReprepMode: ReprepMode?
    @State private var pendingReprepMessage = ""

    private var isApproved: Bool { item.status == .approved }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            contactLine
            venueMatchWarnings
            pressContactWarnings
            duplicateContactWarnings
            confidenceHeldDownWarnings
            addressInAnotherNameWarnings
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
            // #2560: NOT the address. A contact with no name falls back to its address as its identity, and
            // the Contacts block below prints that same address again, as it must (#2015: "It should show
            // me every email it's going to send to"). Counting a rendered card on 2026-08-12 found it twice
            // on a nameless contact, which is the row of #2549's table that change did not reach.
            //
            // The line says what the address cannot instead of repeating it: nobody's name was found. That
            // is worth its place beside the confidence pip, because it is what decides whether the body's
            // greeting can name anyone (#2545), and it leaves the address said exactly once, in the block
            // that carries its send state and its strike control.
            case .email:
                Text("No name for this contact").foregroundStyle(OVColor.inkFaint)
            case let .form(url):
                Link(destination: url) { Label("Contact form", systemImage: "link") }
                    .foregroundStyle(OVColor.forestText)
            case .none:
                Text("No contact found").foregroundStyle(OVColor.inkFaint)
            }
            if let conf = primary?.contactConfidence {
                ConfidencePip(confidence: conf, sourceURL: primary?.contactSourceLinkURL)
            }
            Spacer()
            // #2549: the address is NOT echoed here. It used to be, small and grey on the right, and the
            // Contacts block below the action row printed the same address again: "there are 2 places that
            // say the email, that seems redundant" (Dan, 2026-08-11). The echo justified itself against the
            // LEFT of its own line and never against a block that did not exist in the same breath.
            //
            // The Contacts block is the one that earns it: per contact, carrying the send state and the
            // strike control, and the only one that scales past a single recipient. This line's job is who
            // the draft is addressed to and how confident the guess is, which the name, role and confidence
            // pip already say.
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

    // #1866: the fourth, through the SAME warning row as the three above rather than a new mechanism. It is
    // the only place a contact guard has ever been answerable, so putting the overrule anywhere else would
    // mean two ways to answer a guard depending on which one fired.
    // #2624: the fifth, through the SAME warning row as the four above rather than a new mechanism, for
    // the reason given directly below: this is the only place a contact guard has ever been answerable.
    @ViewBuilder private var addressInAnotherNameWarnings: some View {
        recipientWarning(item.contacts.filter(\.isLooksLikeAnotherPersons),
                        message: { DraftReviewNotes.addressInAnotherName(name: $0.displayName) },
                        dismissLabel: "It reaches them", onDismiss: onDismissAddressInAnotherName)
    }

    @ViewBuilder private var confidenceHeldDownWarnings: some View {
        recipientWarning(item.contacts.filter(\.isHeldDownToUnverified),
                        message: { DraftReviewNotes.confidenceHeldDown(name: $0.displayName) },
                        dismissLabel: "It's their address", onDismiss: onDismissConfidenceHeldDown)
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
    // #2034: the choice itself, shown only where there IS one (two or more contacts with addresses).
    @ViewBuilder private var sendModeChoice: some View {
        if item.offersSendModeChoice, let set = onSetSendsTogether {
            Picker(SendModeCopy.label, selection: Binding(get: { item.sendsTogether }, set: { set($0) })) {
                Text(SendModeCopy.together).tag(true)
                Text(SendModeCopy.separately).tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(SendModeCopy.label)
        }
    }

    // #2545 removed the opening block that used to sit here: a per-contact (or per-joint-email) editable
    // opening, rendered directly above the body, plus a notice saying the body greeted as well and the
    // email would say hello twice. All three were the visible half of a greeting the app composed.
    //
    // Dan, 2026-08-11, reading exactly that stack on one card: "I want to eliminate the appended
    // greeting. It should just be included in the AI prep or manual prep where I write it myself. It's
    // confusing to have it there twice." The greeting is part of the body now, so the body's own box is
    // the whole of what he reads, and the notice has nothing left to warn about. What replaces it is a
    // HOLD, in `sendBlockerNotes` below, where the rest of the reasons a draft will not send already live.

    @ViewBuilder private var draftBlock: some View {
        if editing {
            VStack(alignment: .leading, spacing: OVSpacing.xs) {
                TextField("Subject", text: $draftSubject)
                    .textFieldStyle(.roundedBorder)
                sendModeChoice
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
                sendModeChoice
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
                    // #2007: who wrote it, which is a model on a prepped draft and Dan himself on one he
                    // wrote by hand. Without this the hand-written draft would be the only one on the
                    // screen saying nothing at all about where its words came from.
                    if let author = item.draftAuthorLabel {
                        Text(author).font(.system(size: 10)).foregroundStyle(OVColor.inkFaint)
                    }
                }
                // #367: a re-prep still awaiting the next Prep run, distinct from "Edited" (this
                // just means a run is pending, not that Dan has touched the text).
                // #2548: "Prep queued" on a show no run has ever served, through the one naming rule.
                if item.isReprepQueued {
                    Text(ReprepRequest.queuedBadge(writtenByDan: item.draftWrittenByDan,
                                                   lastServedAt: item.reprepLastServedAt))
                        .font(.system(size: 10)).foregroundStyle(OVColor.gold)
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
        // #843: except while blocked, when the "This draft won't send: …" gate by the button already names
        // the same reason. The decision is DraftReviewNotes', tested, not this view's.
        if DraftReviewNotes.showsBlockingFlagsNearBody(lintBlocked: item.draftLintBlocked) {
            issueFlags(item.draftLintBlockers)
        }
        // #2864: BEFORE, and OUTSIDE, the voice suppression below, deliberately. An advisory finding
        // stands down on Dan's own text (#2131, #459) because when he writes a sentence he means it. That
        // reasoning holds for a judgment about wording and fails for a contradicted fact: he cannot have
        // meant July 18 for a July 25 show, and the sent draft that proved it had `draftEditedByDan` set.
        if let dateWarning = item.eventDateWarning() {
            DraftIssueFlags(findings: [], notes: [dateWarning])
        }
        // #2007: and stand down on text he WROTE for the same reason they stand down on text he edited.
        // The decision is DraftReviewNotes', tested, not this view's.
        if DraftReviewNotes.showsVoiceFindings(editedByDan: item.draftEditedByDan,
                                               writtenByDan: item.draftWrittenByDan),
           let body = item.draftBody {
            issueFlags(DraftCheck.findings(in: body,
                                           title: item.groupName,   // #1141: don't flag the title's own "!"
                                           knownsDate: item.performanceDate != nil,
                                           knownsVenue: item.venue != nil,
                                           // #2531: the ask rule is a COLD pitch rule. A returning client
                                           // reads a different register, and the real email Dan sent one
                                           // asks for nothing by this rule and is right not to.
                                           isColdPitch: item.priorRelationship == "none")
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
    // #2127: one implementation, in DraftIssueFlags, so the cold draft and the reply draft cannot drift.
    @ViewBuilder private func issueFlags(_ findings: [DraftIssue]) -> some View {
        DraftIssueFlags(findings: findings)
    }

    // #2050: every reason this draft will not go out, shown beside whichever button is currently offering
    // to send it. One definition rather than two, because these are the sentences that keep a disabled
    // button from being a dead end (#1311, #2052, #2012), and a copy that drifted onto only one of the two
    // branches would leave exactly the branch nobody was looking at silent.
    @ViewBuilder
    private var sendBlockerNotes: some View {
        // #2050: the reason that now stops EVERY draft in the queue at once, so it is the one most worth
        // saying out loud. Approving used to be reachable without Gmail and only the second screen's Send
        // was gated; with one button the gate moved forward, and a hover is not somewhere Dan will think
        // to look for it. The sentence is GmailCopy's, the same one the button's own help says.
        if !gmailConnected {
            Text(GmailCopy.notConnected)
                .font(.system(size: 10)).foregroundStyle(OVColor.rust).lineLimit(1)
        }
        // #1311: no emailable contact at all, so nothing can ever send. Only when there is genuinely no
        // address: an email held by a review guard is a different, already-explained case.
        if let note = DraftReviewNotes.noSendableEmail(hasPendingRecipient: item.hasPendingRecipient,
                                                       hasAnyEmailContact: item.hasAnyEmailContact) {
            Text(note).font(.system(size: 10)).foregroundStyle(OVColor.rust).lineLimit(1)
        }
        // #2052: a missing subject line, which holds the send just as hard and is two clicks from fixed.
        if let note = DraftReviewNotes.noSubject(subject: item.draftSubject) {
            Text(note).font(.system(size: 10)).foregroundStyle(OVColor.rust).lineLimit(1)
        }
        // #2545: the body must open with a greeting, because nothing composes one above it any more, and
        // a greeting that names one person may only reach one. Both hold the send.
        //
        // It says its piece HERE, beside the button it disables, rather than up by the body: a refusal
        // that only the disabled action could have spoken is a refusal nobody ever reads (L109). #718's
        // two-step override applies unchanged, and tones the sentence down rather than hiding it, so a
        // send that went out despite the warning can still be seen to have. #885: the wording is
        // DraftReviewNotes', tested; the view only decides whether the Override button belongs beside it.
        //
        // Not lineLimit(1), unlike its neighbours: this one names what is wrong AND what to do about it,
        // and truncating it to a single line in a narrow card would cut off the half that helps.
        if let note = DraftReviewNotes.greeting(missing: item.draftMissingGreeting,
                                                misaddressed: item.draftGreetingMisaddressed,
                                                audience: item.greetingAudienceSize,
                                                overridden: item.greetingOverridden,
                                                namesSomeoneElse: item.draftGreetingNamesSomeoneElse,
                                                contactName: item.draftGreetedContactName,
                                                greetedName: item.draftGreetedName) {
            Text(note).font(.system(size: 10)).foregroundStyle(OVColor.rust)
                .fixedSize(horizontal: false, vertical: true)
            if !item.greetingOverridden {
                Button("Override") { showGreetingOverrideConfirm = true }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(OVColor.inkSoft)
            }
        }
        // #789: same shape as the salutation block above, and the same two-step override.
        if let note = DraftReviewNotes.lint(blocked: item.draftLintBlocked,
                                            blockers: item.draftLintBlockers) {
            Text(note).font(.system(size: 10)).foregroundStyle(OVColor.rust).lineLimit(1)
            if item.draftLintBlocked {
                Button("Override") { showLintOverrideConfirm = true }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(OVColor.inkSoft)
            }
        }
        if let line = SendFailureLine.text(for: item.sendError) {
            Text(line).font(.system(size: 10)).foregroundStyle(OVColor.rust).lineLimit(1)
        }
    }

    private var actionRow: some View {
        HStack(spacing: OVSpacing.xs) {
            // "Sent" only once EVERY recipient has gone. A multi-recipient show keeps the Send button
            // (it stays approved with a pending recipient) even after the first email, so each recipient
            // gets its own click (#394).
            if item.isSent && !item.hasPendingRecipient {
                Label("Sent", systemImage: "paperplane.fill")
                    .font(OVType.meta).foregroundStyle(OVColor.forestText)

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
                        // #2876: this opens the send review, it does not send. Named for what it does.
                        Label(SendConfirmCopy.openReview, systemImage: "paperplane")
                            .font(OVType.meta).foregroundStyle(OVColor.onForest)
                            .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                            .background(Capsule().fill(OVColor.forest))
                    }
                    .buttonStyle(.plain)
                    .disabled(!gmailConnected || !item.hasPendingRecipient)
                    .help(GmailCopy.sendHelp(connected: gmailConnected,
                                             whenConnected: SendConfirmCopy.openReviewHelp("email")))
                    Button("Unapprove") { onUnapprove() }
                        .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    // #2073: the missing-subject note beside Send says "Edit the draft", so the control
                    // performing it must sit on this card too, not only on the unapproved one. Editing
                    // does not unapprove: the text stays Dan's either way, and the send confirmation
                    // still shows the final email before anything leaves.
                    Button("Edit") {
                        draftSubject = item.draftSubject ?? ""
                        draftBody = item.draftBody ?? ""
                        editing = true
                    }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    reprepControl
                    sendBlockerNotes
                }
                Spacer()
            } else if case let .ready(recipientId, formURL) = item.formPitch {
                let isSocial = Reachability.isSocialOnly(formURL)
                // #1630: this show has no address at all, so Approve is permanently disabled and there is
                // no other way forward. Dan pitches it by hand; this is the only control that matters here.
                Button { onBeginFormPitch(recipientId, formURL) } label: {
                    Label(FormOutreachCopy.copyAndOpen(isSocial: isSocial), systemImage: "doc.on.clipboard")
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
                // #1828: this is the card that needs Re-prep MOST. The show has no address at all, so
                // "find contacts only" is the highest-value action available on it, and it was the one
                // branch that never drew the control.
                reprepControl
                Spacer()
            } else if case let .awaitingConfirmation(recipientId, routeURL, startedAt) = item.formPitch {
                Text(FormOutreachCopy.awaitingQuestion(startedAt: startedAt, now: Date(),
                                                       isSocial: Reachability.isSocialOnly(routeURL)))
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
                // #2050: ONE button, carrying the draft all the way to sent. It used to say "Approve", and
                // approving moved the show to a second screen with its own Send, which is the screen Dan
                // could not find his email on: "There's no real reason to approve it again on another
                // screen." It says "Final review" rather than "Send" because pressing it does not send:
                // it opens the confirmation sheet that shows the whole email and who it reaches, and THAT
                // sheet's Send commits. A button naming an act it does not perform is the thing this
                // screen can least afford.
                // #2876: that rule was right and covered only THIS branch. The approved branch above ran
                // the same `onSend()` under the label "Send", so one action carried two labels on one
                // screen and the honest one was the one Dan met less often. Both now use the shared
                // constant, whose wording says the send that follows as well as the review that comes
                // first, which "Final review" left him to infer.
                Button { onSend() } label: {
                    Text(SendConfirmCopy.openReview).font(OVType.meta).foregroundStyle(OVColor.onForest)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                        .background(Capsule().fill(OVColor.forest))
                }
                .buttonStyle(.plain)
                // #399: hasPendingRecipient means "at least one recipient still pending with a real
                // address", exactly what this gate needs. #2050: and Gmail, which the old Send button
                // gated on and the old Approve did not have to, because this button now leads to a send.
                .disabled(!gmailConnected || !item.hasPendingRecipient)
                .help(GmailCopy.sendHelp(connected: gmailConnected,
                                         whenConnected: "Read the email one last time, then send it"))
                Button("Edit") {
                    draftSubject = item.draftSubject ?? ""
                    draftBody = item.draftBody ?? ""
                    editing = true
                }
                .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                reprepControl
                // #2050/#2012: the same explanations that used to appear only after approving. The button
                // above is disabled by exactly the things these name, and Dan met it greyed with nothing
                // said beside it, on the one screen where a dead end costs him the pitch.
                sendBlockerNotes
            }
            if !isApproved { Spacer() }
        }
        // #2545: the greeting hold's own two-step confirm. The message is built from the SAME sentence the
        // note above shows, so the warning and the confirm can never describe different problems.
        .alert("Send anyway?", isPresented: $showGreetingOverrideConfirm) {
            Button("Send Anyway") { onOverrideGreeting() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DraftReviewNotes.greetingOverrideConfirm(missing: item.draftMissingGreeting,
                                                          misaddressed: item.draftGreetingMisaddressed,
                                                          audience: item.greetingAudienceSize,
                                                          namesSomeoneElse: item.draftGreetingNamesSomeoneElse,
                                                          contactName: item.draftGreetedContactName,
                                                          greetedName: item.draftGreetedName))
        }
        // #789: the draft lint's own override, deliberately a separate confirm from the greeting one
        // above, so the reason Dan is waving something through is never ambiguous.
        .alert("Send anyway?", isPresented: $showLintOverrideConfirm) {
            Button("Send Anyway") { onOverrideDraftLint() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DraftReviewNotes.lintOverrideConfirm(blockers: item.draftLintBlockers))
        }
        // #733: guard against repeatedly re-prepping the same prospect. #2007: and against replacing an
        // email Dan wrote himself. The sentence is chosen in ReprepRequest.confirmation.
        // #2548: titled through the one naming rule, so it cannot say "Re-prep" over a control saying
        // "Prep".
        .alert(ReprepRequest.confirmTitle(writtenByDan: item.draftWrittenByDan,
                                          lastServedAt: item.reprepLastServedAt),
               isPresented: $showReprepConfirm) {
            Button(ReprepRequest.verb(writtenByDan: item.draftWrittenByDan,
                                      lastServedAt: item.reprepLastServedAt)) {
                if let mode = pendingReprepMode { onReprep(mode) }
                pendingReprepMode = nil
            }
            Button("Cancel", role: .cancel) { pendingReprepMode = nil }
        } message: {
            Text(pendingReprepMessage)
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
        // #2548: "Prep" when no run has ever served this show and the only draft is Dan's own.
        Menu(ReprepRequest.menuLabel(writtenByDan: item.draftWrittenByDan,
                                     lastServedAt: item.reprepLastServedAt)) {
            Button("Redraft only") { requestReprep(.draftOnly) }
                .disabled(item.isSent)
            Button("Find contacts only") { requestReprep(.contactsOnly) }
            Button("Redraft and find contacts") { requestReprep(.both) }
                .disabled(item.isSent)
        }
        .disabled(item.isReprepQueued)
        .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
    }

    // #2007: one decision covers both reasons a re-prep confirms (the #733 cooldown, and replacing text
    // Dan wrote himself), so a single click can never raise two alerts in a row.
    private func requestReprep(_ mode: ReprepMode) {
        guard let message = ReprepRequest.confirmation(mode: mode, writtenByDan: item.draftWrittenByDan,
                                                       lastServedAt: item.reprepLastServedAt, now: Date())
        else {
            onReprep(mode)
            return
        }
        pendingReprepMessage = message
        pendingReprepMode = mode
        showReprepConfirm = true
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

    // #399: opens a small popover to type a route (required) and name (optional). The add itself
    // runs the duplicate/venue check (ManualRecipientCheck via ProspectMutations); this view never
    // blocks the add on its own, it only requires a plausible route before enabling the button.
    //
    // #2629: a ROUTE, not only an address. The card tells Dan "No email to send to. Add a contact by
    // hand" on a show with no emailable contact, and this is the control that sentence points at, so
    // until now the only route those shows actually have (a contact form on the producer's own site, or
    // since #2612 an Instagram he will DM) was the one thing it could not accept. He met an instruction
    // that could not be followed. Enabled and refused through the SAME `ManualContactRoute.parse` the add
    // uses, so the button cannot look willing to take something the add then rejects (L109).
    private var addContactButton: some View {
        Button { showAddContact = true } label: {
            Label("Add contact", systemImage: "plus.circle")
                .font(OVType.meta).foregroundStyle(OVColor.forestText)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAddContact, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: OVSpacing.sm) {
                Text("Add a contact").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                TextField("Email or link", text: $addContactEmail)
                    .textFieldStyle(.roundedBorder)
                // Says what a link MEANS for him rather than restating the field's own label, which has
                // already said that a link is allowed. The load-bearing half is that a route is not a
                // send: he opens it and writes there himself, which is the difference that decides
                // whether this show is usable at all (#843: a second line must add something).
                Text("You'll open a form or profile and write there by hand.")
                    .font(OVType.meta).foregroundStyle(OVColor.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
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
                    // #2023: one readable route, the same rule the add itself is gated on, so this
                    // cannot look enabled on a pasted "a@x.org, b@y.org" and then be refused.
                    // #2629: through the route parser, so a form or profile link enables it too.
                    .disabled(ManualContactRoute.parse(addContactEmail) == nil)
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
                if item.nextRecipientIds.contains(c.id) {
                    // #2033: on a show sending together, every one of them is on the same email, so the
                    // tag has to say that rather than claiming each is the one it goes to.
                    Text(DraftContactCopy.nextSendTag(recipients: item.nextRecipientIds.count))
                        .font(OVType.tag).foregroundStyle(OVColor.gold)
                }
                // On the show but NOT going to be emailed, so the list does not overstate itself.
                if c.isHeldFromSending {
                    // #2017: the shared constant, because the send sheet's contact picker says the same
                    // thing about the same contact and two copies of one sentence drift (#843).
                    Text(SendConfirmCopy.heldTag).font(OVType.tag).foregroundStyle(OVColor.rust)
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
                        // #2395: the same five endings the reached-out row offers, from the one
                        // vocabulary, rather than this menu's own four spellings of them. Two of the old
                        // items were never endings at all and stay below the divider as what they are: a
                        // delivery fact Overture detects, and taking a contact out of the pursuit.
                        ForEach(ShowOutcome.pitched, id: \.self) { outcome in
                            Button(outcome.label) {
                                onRecordOutcome(outcome)
                                // #769: a refusal is ambiguous, and the two readings have wildly
                                // different consequences. Ask once, here, in the moment Dan has actually
                                // read the reply, rather than guessing or relying on him to remember an
                                // org-level action later, which is exactly when he won't.
                                if outcome == .theySaidNo { askAboutWholeOrg = true }
                            }
                        }
                        // #2395: taking an ending back. The old "In conversation" item was never an
                        // ending, and what it actually did was clear one, so that capability keeps its own
                        // control rather than disappearing with the word. Shown only when there is
                        // something to reopen, so it never offers to undo nothing.
                        if item.showOutcome != nil {
                            Button(ShowOutcome.reopenLabel) { onReopenOutcome() }
                        }
                        Divider()
                        Button("Bounced") { onMarkContact(c.id, nil, true) }
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
            // #2934: `replied` is not the question. An answered conversation is still `replied`, and the
            // block used to come up on this card with its "Draft a reply" button, for a run that refuses
            // it. The mode decides, and a conversation with nothing to show draws nothing.
            if c.replied && c.replyConversationMode != .closedNothingToShow { replyDraftBlock(c) }
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
    // #2127: the reply surface itself lives in ReplyConversationView, shared with the reached-out queue,
    // so answering a reply is not something only this card can do.
    @ViewBuilder private func replyDraftBlock(_ c: RecipientSnapshot) -> some View {
        ReplyConversationView(contact: c,
                              lintTitle: item.groupName,   // #1141: don't flag the title's own "!"
                              knownsDate: item.performanceDate != nil,
                              knownsVenue: item.venue != nil,
                              gmailConnected: gmailConnected,
                              sendingSince: replySendSince(c.id),
                              onDraftReply: onDraftReply,
                              onSendReply: onSendReply,
                              onCopyReply: onCopyReply,
                              onConfirmCopiedReplySent: onConfirmCopiedReplySent,
                              onEditReplyDraft: onEditReplyDraft,
                              onCancelReplyDraft: onCancelReplyDraft)
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
        if c.resolution == .booked { return OVColor.forestText }
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
        case .booked: return OVColor.forestText
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
        performanceDate: "2026-09-01", sourceListingURL: nil,
        priorRelationship: "warm", production: "self", profile: "strong", coverage: "likely_uncovered",
        fitScore: 8, tier: "high", fitReason: "Repeat-client-adjacent ensemble at a flagship venue.",
        matchedClientName: "Aurora Strings", possibleMatchSource: nil, possibleMatchName: nil, status: .approved)
    var emma = RecipientSnapshot(id: "emma@aurorastrings.example", name: "Emma Robinson",
                                 email: "emma@aurorastrings.example", role: "Marketing & Communications Manager",
                                 provenance: .act, sendState: .sent, replied: true, lastReplyText: nil,
                                 resolution: nil, bounced: false, outcomeSource: .manual)
    emma.contactConfidence = .high
    item.contacts = [emma]
    item.draftSubject = "Photographing Aurora Strings at Carnegie Hall."
    item.draftBody = "Hi Emma, I photograph performing arts in New York and saw Aurora Strings is at Carnegie Hall. I shoot unobtrusive, no-flash documentary coverage and think it would suit this program."
    item.sentAt = Date()
    return DraftReviewView(item: item, onUnapprove: {}, onSaveDraft: { _, _ in })
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
        case .onTrack: return OVColor.forestText
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
            case .high: return OVColor.forestText
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
