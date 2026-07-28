import Foundation
import SwiftData

// Where a recipient came from. `act` = a single-act waterfall result; `performer` = a named
// individual performer on a self-produced show (#587, #366 Phase 2), mutually exclusive with `act`
// per performance (never both used at once); `presenter` = a real presenting org (never the host
// venue); `manual` = an address Dan typed in at approval.
enum RecipientProvenance: String, Codable, CaseIterable, Sendable {
    case act, performer, presenter, manual

    // #885: the codebase's convention is a `.label` on the enum (ConversationState, ArchiveStatus,
    // PerformanceStatus and DismissReason all have one). This one was a switch inside a view body.
    var label: String {
        switch self {
        case .act: return "act"
        case .performer: return "performer"
        case .presenter: return "presenter"
        case .manual: return "added"
        }
    }
}

// A recipient's place in sending. Distinct from a performance's review status (ReviewStatus);
// "suppressed" is an unsent send cancelled because the performance froze (any-yes rule).
// "sending" is claimed synchronously right before the network call (#475/#476): it closes the
// double-send race (a second call sees anything but .pending and backs off) and, persisted before
// the await, survives a crash so an interrupted send is never silently re-queued as still-pending.
enum SendState: String, Codable, CaseIterable, Sendable {
    case pending, sending, sent, suppressed
}

// Why a recipient carries sendState == .suppressed (#542): the original booking-freeze only ever
// meant "the show got booked elsewhere," but the same freeze now also fires on a manual decline or
// closing note, so the label shown for a suppressed contact needs to say which actually happened.
// Only meaningful while sendState == .suppressed.
// #399: a third reason, distinct from an actual outcome. removedByDan means Dan hand-removed an
// already-sent contact without recording a decline (reply/decline stats stay honest); the other
// two cases both reflect a real event (the show booked elsewhere, or this contact declined).
enum RecipientSuppressionReason: String, Codable, CaseIterable, Sendable {
    case bookedElsewhere, declined, removedByDan
}

// A recipient's terminal commercial outcome (#389 derived-outcome model). The active states
// (pending / awaiting / in conversation) are inferred from sendState + replied + bounced; this
// captures only the resolutions that aren't otherwise knowable. `booked` is the attribution of the
// performance's single booking to the contact who landed it, never a second booking. Phase 5 reads
// this to derive the performance status.
enum RecipientResolution: String, Codable, CaseIterable, Sendable {
    case booked
    case declinedSoft = "declined_soft"  // a "no" with the door left open
    case declinedHard = "declined_hard"  // not interested
}

// One party emailed for a performance: an act contact, a presenter, or a manual add. A performance
// holds one or more of these as its own SwiftData rows (#409, promoted from a JSON blob so editing
// one recipient can't overwrite another's state and the row identity survives a form-only contact
// gaining an email). Each carries its own send + engagement state so reply detection, follow-ups, and
// reminders are per-recipient, while booking and the one draft stay on the performance.
@Model
final class Recipient {
    // Identity + contact. `id` is the canonicalized email when there is one, otherwise the contact
    // form URL (a form-only act, #368), so the SAME recipient is kept when Dan fills in an email
    // later. `email` is nil for a form-only contact until Dan adds one. NOTE: `id` is deliberately
    // NOT @Attribute(.unique): the same act emailed for two performances shares an id, and a unique
    // constraint would merge those rows across prospects.
    var id: String = ""
    var email: String?
    var name: String?
    var role: String?
    var provenanceRaw: String = RecipientProvenance.manual.rawValue
    var contactMethodRaw: String?
    var contactConfidenceRaw: String?
    var contactFormURL: String?
    // #363: the page this contact was actually read from, so the confidence badge can link Dan
    // through to verify it himself. Only ever meaningful when contactConfidence == .high;
    // RecipientSnapshot.contactSourceLinkURL is the single place that gate is enforced for
    // display, so a stale value left over from a since-downgraded confidence is inert rather
    // than shown as a false citation. Distinct from contactFormURL, which stays the form_or_dm
    // contact's own submission link.
    var contactSourceURL: String?
    // v4 (#640, #634 Phase B): only ever meaningful when provenance == .performer, a direct,
    // second-person draft for THIS recipient, preferred over the shared Prospect.draftBody at send.
    // PrepImporter clears this whenever a re-ingested contact's provenance is no longer .performer.
    var overrideBody: String?

    // #789: the EXACT text Dan explicitly confirmed is fine to send despite a blocking lint finding.
    // A copy of the text rather than a bare boolean, so a later edit to DIFFERENT text silently
    // invalidates the override with no migration bookkeeping (isLintOverridden below); the same
    // shape as Prospect.draftSalutationReviewOverriddenBody (#718). Per RECIPIENT, not per prospect,
    // because the text that reaches each one can differ (see effectiveBody).
    var lintOverriddenBody: String?

    // #388: a heuristic guess (VenueContactGuard) that this contact's address belongs to the host
    // venue, not the act/presenter, set on ingest and blocking sendability until Dan dismisses it
    // (a weaker signal than the runbook's own STRICT venue-disqualify rule for the AI, so it's
    // reversible rather than absolute).
    var looksLikeVenue: Bool = false
    var looksLikeVenueDismissed: Bool = false

    // #722: same shape as looksLikeVenue above, for the runbook's separate press/media-disqualify
    // rule (#635); a heuristic guess (PressContactGuard), dismissible for the same reason.
    var looksLikePressContact: Bool = false
    var looksLikePressContactDismissed: Bool = false

    // #726: a heuristic guess (DuplicateContactGuard) that this contact is already being pitched
    // on another still-open prospect for what looks like the same real-world performance, a
    // safety net for #369's grouping. Dismissible for the same reason as the two flags above.
    var looksLikeDuplicateContact: Bool = false
    var looksLikeDuplicateContactDismissed: Bool = false

    // #1630: HOW this contact was actually reached. nil means email, the only channel that existed
    // before this, so every stored record migrates as what it is. `contact_form` means Dan submitted
    // the act's own form by hand and told Overture he did: real outreach that Gmail never touched, so
    // it has no thread to watch and no message id. Raw so a future channel decodes here without a
    // migration.
    var outreachChannelRaw: String?
    // When Dan confirmed he sent it. This is the form channel's counterpart to `gmailMessageId`: the
    // evidence that the outreach actually happened, as opposed to a bare `sentAt` that proves nothing
    // (#963). nil on every email send.
    var formOutreachRecordedAt: Date?
    // The form Dan actually submitted, frozen at that moment. NOT read back off `contactFormURL`,
    // which is scout-owned and rewritten by every re-ingest (PrepImporter), so the record would
    // otherwise end up naming a page he never used (L37).
    var formOutreachURL: String?

    // Per-recipient send + engagement.
    var sendStateRaw: String = SendState.pending.rawValue
    // Why sendState == .suppressed (#542). Only meaningful while sendState == .suppressed; nil for
    // every other state and for any suppression that predates this field.
    var suppressionReasonRaw: String?
    var sentAt: Date?
    var gmailThreadId: String?
    var gmailMessageId: String?
    // #483: set when a send succeeded but Gmail's response had no parseable threadId, so this
    // recipient's replies can never be auto-detected until Dan checks Gmail directly.
    var replyTrackingDegraded: Bool = false
    var sendError: String?
    // When the current .sending claim was made (#475/#476); cleared when it resolves to .sent or
    // reverts to .pending. Only meaningful while sendState == .sending.
    var sendClaimedAt: Date?
    // #468 (SUP-005): the same claim-before-await pattern as sendClaimedAt, for a reply send.
    // Kept on its OWN field (not shared with nudgeSendClaimedAt below) because a replied
    // recipient can legitimately be due for a conversation nudge at the same time (two different
    // open surfaces), so sharing would cause spurious refusals rather than catching a real race.
    var replySendClaimedAt: Date?
    // #468 (SUP-005): shared by sendFollowUp and sendConversationNudge. Safe to share: a
    // recipient eligible for a follow-up (isAwaitingFollowUp, which requires outcomeSourceRaw ==
    // nil) and one eligible for a conversation nudge (which requires a conversationState, and
    // setConversationState always pairs that with outcomeSourceRaw = .manual) are mutually
    // exclusive by construction, so a recipient can never legitimately want both at once.
    var nudgeSendClaimedAt: Date?
    var followUpCount: Int = 0
    var lastFollowUpAt: Date?
    var replied: Bool = false
    var repliedAt: Date?
    var lastReplyId: String?
    var dismissedReplyId: String?
    var lastReplyText: String?
    var bounced: Bool = false
    // The Gmail message id of the auto-detected hard bounce that set `bounced` (#398), and the
    // one Dan said was wrong, mirroring lastReplyId/dismissedReplyId so a dismissed false
    // positive never re-flags while a genuinely new bounce still does.
    var lastBounceId: String?
    var dismissedBounceId: String?
    // #656: when the newest Gmail delay notice was first seen on this thread, paired with its
    // message id so a fresh delay notice restarts the fade window without re-triggering on the
    // same one repeatedly. Purely informational: never gates isSilent or follow-up eligibility,
    // and BounceService leaves both alone once bounced/replied (see the isSilent guard above).
    var delayNoticeAt: Date? = nil
    var lastDelayMessageId: String? = nil
    // Per-recipient conversation state (#650, Phase 1 of milestone #19), mirroring the four fields
    // already on Prospect exactly. The per-recipient conversation surface that sets these is a later
    // phase; for now this is a pure domain addition plus the migration in Task 3.
    var conversationStateRaw: String? = nil
    var conversationStateSetAt: Date? = nil
    var conversationRemindedAt: Date? = nil
    var conversationStateSourceRaw: String? = nil
    var resolutionRaw: String?
    // Whether Dan hand-set this recipient's state (#418 A1b), mirroring Prospect.outcomeSourceRaw:
    // nil = no manual mark, OutcomeSource.manual = Dan judged this contact by hand. Per-recipient
    // reply detection short-circuits on this so one contact's manual mark can't blind the others.
    var outcomeSourceRaw: String?
    // Reply-triage auto-pause (#418 A4): a reply on the show pauses this still-unsent recipient
    // pending Dan's triage. Its OWN flag, distinct from sendState .suppressed (the booking-freeze).
    var pausedByReply: Bool = false
    // AI inbound-reply drafter outputs (#420 C0). `intentHint` is a NON-BINDING ReplyIntent hint shown
    // beside the manual controls; it never auto-sets a RecipientResolution (#420 C4). `replyDraft*` is
    // the drafted response Dan reviews; `replyDraftRequestedAt` stamps the request so the conversation
    // view can show progress and a timeout can surface a dead run as needs-attention (#420 C6).
    var replyDraftSubject: String?
    var replyDraftBody: String?
    var replyDraftRequestedAt: Date?
    var intentHint: String?
    // Whether Dan hand-edited THIS reply draft (#459), mirroring Prospect.draftEditedByDan for the cold
    // draft: once set, the deterministic DraftCheck warnings stop nagging on text he already owns. A
    // fresh AI draft clears it again so warnings reappear on text he hasn't touched.
    var replyDraftEditedByDan: Bool = false
    // #846: which model wrote this reply, mirroring Prospect.draftModel for the cold draft. The runner
    // has stamped it into the results file since #804; the app decoded it nowhere and threw it away, so
    // the reply half of that record never existed. A reply goes to somebody who already wrote back to
    // Dan, which is a warmer lead than any cold pitch (#874), and it is exactly where he would want to
    // check what wrote the words. Defaulted, so replies drafted before this migrate cleanly carrying no
    // trace.
    var replyDraftModel: String? = nil

    // The reply-draft voice-learning pair (#463), mirroring Prospect.originalDraft*/sentBody for the cold
    // draft. originalReplyDraftBody is the AI's reply before Dan's first substantive edit; sentReplyBody
    // is the exact text he committed (sent via Overture or copied out to Gmail), frozen at commit so a
    // later re-draft can't rewrite the lesson. Reply subjects are auto ("Re: …"), never Dan-edited, so
    // only the body is captured.
    var originalReplyDraftBody: String?
    var sentReplyBody: String?
    var replySentAt: Date?

    // The performance this recipient belongs to (inverse of Prospect.recipients).
    var prospect: Prospect?

    init(id: String, email: String?, name: String? = nil, role: String? = nil,
         provenance: RecipientProvenance,
         contactMethodRaw: String? = nil, contactConfidenceRaw: String? = nil,
         contactFormURL: String? = nil, contactSourceURL: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
        self.role = role
        self.provenanceRaw = provenance.rawValue
        self.contactMethodRaw = contactMethodRaw
        self.contactConfidenceRaw = contactConfidenceRaw
        self.contactFormURL = contactFormURL
        self.contactSourceURL = contactSourceURL
    }

    // The stable join + dedupe key: the canonicalized email when present, else the form URL (so a
    // form-only contact survives an email being added later), else nil when there is neither and so
    // nothing to make a recipient from.
    static func makeId(email: String?, formURL: String?) -> String? {
        if let email, !email.isEmpty { return ReplyDetection.email(from: email) }
        if let formURL, !formURL.isEmpty { return "form:" + formURL }
        return nil
    }

    var provenance: RecipientProvenance {
        get { RecipientProvenance(rawValue: provenanceRaw) ?? .manual }
        set { provenanceRaw = newValue.rawValue }
    }

    var sendState: SendState {
        get { SendState(rawValue: sendStateRaw) ?? .pending }
        set { sendStateRaw = newValue.rawValue }
    }

    // Defaults to .bookedElsewhere so a suppression from before this field existed (every one of
    // them was a booking-freeze) still reads correctly rather than as an unrepresentable nil (#542).
    var suppressionReason: RecipientSuppressionReason {
        get { suppressionReasonRaw.flatMap(RecipientSuppressionReason.init) ?? .bookedElsewhere }
        set { suppressionReasonRaw = newValue.rawValue }
    }

    var resolution: RecipientResolution? {
        get { resolutionRaw.flatMap(RecipientResolution.init) }
        set { resolutionRaw = newValue?.rawValue }
    }

    var outcomeSource: OutcomeSource? {
        get { outcomeSourceRaw.flatMap(OutcomeSource.init) }
        set { outcomeSourceRaw = newValue?.rawValue }
    }

    // #654: mirrors Prospect's own contactMethod/contactConfidence wrappers, now the only copy since
    // the lead-level ones were deleted.
    var contactMethod: ContactMethod? {
        get { contactMethodRaw.flatMap(ContactMethod.init) }
        set { contactMethodRaw = newValue?.rawValue }
    }

    var contactConfidence: ContactConfidence? {
        get { contactConfidenceRaw.flatMap(ContactConfidence.init) }
        set { contactConfidenceRaw = newValue?.rawValue }
    }

    var conversationState: ConversationState? {
        get { conversationStateRaw.flatMap(ConversationState.init) }
        set { conversationStateRaw = newValue?.rawValue }
    }

    // #16: every stage this conversation has DEMONSTRABLY reached, in the order it first reached each.
    // `conversationStateRaw` holds only where the conversation IS, so a contact who asked a question and
    // then decided to book stopped recording that a question was ever asked, and nothing could recover
    // it afterwards. The funnel's middle band counts conversations that PASSED THROUGH a stage, which
    // the single current value cannot answer.
    //
    // A list rather than one Bool per stage: the stages are an enum that may grow, and four parallel
    // flags would need a fifth adding by hand in every place that reads them (the #1030-class defect
    // where one concept lives in several switches). Appended to, never removed: this is a record of
    // where a conversation has been, so changing or clearing the current stage leaves it untouched.
    //
    // Written ONLY by Dan's own assertion, setConversationState and confirmConversationState. NOT by
    // the shared setter above, which the AI's suggestion path also passes through: an automatic guess he
    // never confirmed (or overrode) must leave no trace, or a wrong AI read would be baked into the
    // permanent record with no way to tell it from his own call (Dan's decision, 2026-07-23).
    var conversationStagesReached: [String] = []

    // Idempotent by construction, so a stage set twice counts one conversation rather than two clicks.
    private func markStageReached(_ state: ConversationState) {
        guard !conversationStagesReached.contains(state.rawValue) else { return }
        conversationStagesReached.append(state.rawValue)
    }

    var conversationStateSource: OutcomeSource? {
        get { conversationStateSourceRaw.flatMap(OutcomeSource.init) }
        set { conversationStateSourceRaw = newValue?.rawValue }
    }

    // #1630: this contact was provably reached, whichever way it happened. An emailed contact proves it
    // with a Gmail message id against a real address (#331/#378: a bare `sentAt` with neither is a
    // staged or corrupt record that was never actually sent, and that guard is unchanged). A form
    // contact proves it with Dan's own confirmation, which is a different KIND of evidence, not the
    // absence of any. The one place that question is answered, so a surface cannot admit an outreach
    // the next surface refuses.
    var hasProvenOutreach: Bool {
        if formOutreachRecordedAt != nil { return true }
        return gmailMessageId != nil && (email?.isEmpty == false)
    }

    // Sent, no reply, not bounced: the only recipients that receive follow-ups or reminders.
    var isSilent: Bool { sendState == .sent && !replied && !bounced }

    // The contacts the follow-up sequencer may nudge (#418 D): silent AND not hand-resolved. A contact
    // Dan marked Closed/Booked (resolution set) or otherwise judged by hand (outcomeSource == .manual)
    // is still "silent" by the raw definition but must never be nudged again.
    // #1630: and never a form outreach. A nudge is an EMAIL, sent onto the original thread; a form
    // contact has neither an address nor a thread, so the whole sequence is unsendable for it. Offering
    // one would put a button in Follow-ups that can only fail, about a pitch that is perfectly fine. Its
    // own decide clock (ReachedOutQueue) covers it instead.
    var isAwaitingFollowUp: Bool {
        isSilent && resolution == nil && outcomeSource != .manual && outreachChannel == .email
    }

    // #677: this contact replied and nobody has dealt with it yet: replied, no resolution recorded,
    // and it didn't bounce. Was independently recomputed in OmniFocusSync, ReachedOutQueue, and
    // ConversationReminder (plus inline in Prospect.hasUnhandledReply); now the one shared source. A
    // manually hand-set conversation state (#653) is NOT excluded here: only two of the four call
    // sites need that exclusion, so they layer `&& conversationStateSource != .manual` on top.
    var hasUnhandledReply: Bool { replied && resolution == nil && !bounced }

    // Ready to actually receive the pitch: still pending and has a real address. A form-only contact
    // (#368) is pending but has no email, so it is never auto-sendable until Dan fills one in. The send
    // queue, the manual-send picker, and the "show fully sent?" rollup all read this one predicate.
    // A contact auto-paused by a reply on the same show (#430) is held back until Dan triages, so it
    // drops out of every send path that reads this predicate. #407: a performance whose draft still
    // carries an old, un-strippable inline greeting is blocked ENTIRELY (every recipient, not just a
    // differently-named one) until that clears OR Dan explicitly overrides it (#718,
    // Prospect.isSalutationReviewOverridden); a recipient with no prospect wired (every bare-
    // Recipient unit test in this file) is unaffected, since there is nothing to check. #388: a
    // recipient whose address looks like the host venue (VenueContactGuard, set at ingest) is
    // blocked until Dan dismisses that specific guess as wrong.
    // #789 adds the draft lint: a recipient whose OWN outgoing text carries a blocking finding is
    // held back until Dan either fixes the text or deliberately overrides it, the same way #407's
    // salutation flag blocks above.
    var isSendablePending: Bool {
        sendState == .pending && (email?.isEmpty == false) && !pausedByReply
            // #901: a date conflict Dan has not cleared stops the send, not just the draft. The prep gate
            // alone would miss the case that matters most: the draft already existed, was approved, and
            // THEN he blocked the week or took a booking. Nothing should go out pitching a night he
            // cannot work until he says he can.
            && prospect?.hasUnclearedConflict != true
            && (prospect?.draftNeedsSalutationReview != true || prospect?.isSalutationReviewOverridden == true)
            && !(looksLikeVenue && !looksLikeVenueDismissed)
            && !(looksLikePressContact && !looksLikePressContactDismissed)
            && !(looksLikeDuplicateContact && !looksLikeDuplicateContactDismissed)
            && !isBlockedByDraftLint
    }

    // #789 / #641: the text THIS recipient actually receives. A directly-addressed performer's own
    // second-person draft (#634 Phase C) wins over the shared third-person body; for everyone else
    // it IS the shared body. SendService.deliver reads this to compose the mail, and the lint below
    // reads the same property to judge it, so what is CHECKED can never drift from what is SENT.
    var effectiveBody: String? {
        (provenance == .performer ? overrideBody : nil) ?? prospect?.draftBody
    }

    // #789: the blocking lint findings in that text. Derived live rather than stored at ingest on
    // purpose: it is a pure function of text already on disk, so it can never go stale, it needs no
    // migration, and it covers Dan's own edits and a performer's override body for free.
    var draftLintBlockers: [DraftIssue] {
        guard let body = effectiveBody, !body.isEmpty else { return [] }
        return DraftCheck.blockingFindings(in: body)
    }

    // True only when the current outgoing text is the EXACT text Dan overrode; a mismatch (edited
    // since, or never overridden) means the block still applies.
    var isLintOverridden: Bool {
        lintOverriddenBody != nil && lintOverriddenBody == effectiveBody
    }

    var isBlockedByDraftLint: Bool { !draftLintBlockers.isEmpty && !isLintOverridden }

    // #792: a real contact, with a real address, held back by one of the review guards and waiting on a
    // single glance from Dan.
    //
    // This is NOT the same as "not sendable", and conflating the two is the bug. `isSendablePending` is
    // false for a contact that is FINISHED (already sent, deliberately suppressed, no address at all)
    // and equally false for one that is WAITING. SendService reads it to decide the show is contacted,
    // so a held contact made the whole show read as fully Sent and leave the queue, while that person
    // never received anything and nothing afterwards surfaced them. The held contact is usually the one
    // worth emailing: the act's own address, held back by a heuristic Dan only has to look at to dismiss.
    //
    // A contact paused because the org REPLIED is deliberately not counted. Nothing is blocking it; Dan
    // is choosing not to email again while a conversation is live, and nagging him about that would be
    // nagging him about a thing that is working.
    var isBlockedAwaitingReview: Bool {
        guard sendState == .pending, email?.isEmpty == false, !pausedByReply else { return false }
        return (prospect?.draftNeedsSalutationReview == true && prospect?.isSalutationReviewOverridden != true)
            || (looksLikeVenue && !looksLikeVenueDismissed)
            || (looksLikePressContact && !looksLikePressContactDismissed)
            || (looksLikeDuplicateContact && !looksLikeDuplicateContactDismissed)
            || isBlockedByDraftLint
    }

    // Deterministic send order. SwiftData to-many relationships are UNORDERED, so the send queue and
    // the manual-send picker must impose a stable order or "the next recipient" (and which address each
    // click sends) would vary run to run. Act/performer contacts go first (mutually exclusive per
    // performance, so they tie), then a presenter, then a manual add (the #366/#368 contact ladder:
    // target the act or performer; the presenter only after), ties broken by id.
    var sendOrderRank: Int {
        switch provenance {
        case .act, .performer: return 0
        case .presenter: return 1
        case .manual: return 2
        }
    }

    var firstName: String { Salutation.firstName(name) }

    // Manual-judge outcome marking (#418 B2). Dan hand-sets THIS contact's outcome from the
    // conversation surface, after reading the reply in Gmail. Stamps `outcomeSource = .manual` so
    // per-recipient detection (A2) never overwrites his call, including an "In conversation" mark,
    // which sets the source flag even though it sets no resolution. The locked vocabulary maps onto
    // existing fields with NO new enum: In conversation = (nil, false), Booked = (.booked, false),
    // Closed-not-now = (.declinedSoft, false), Closed-no = (.declinedHard, false), Bounced = (nil, true).
    //
    // ATTRIBUTION ONLY for `.booked`: this attributes the single lead booking to the contact who
    // landed it (`resolution` doc, #389). It does NOT create or count a lead booking and does NOT set
    // `prospect.outcome`; the lead booking stays fully lead-level via DownbeatBooking.reconcileBooked
    // (locked decision g). Phase F's derivation reads `resolution == .booked` for attribution display
    // only; never wire this into the lead booking count.
    func markOutcomeManually(resolution: RecipientResolution?, bounced: Bool = false) {
        self.resolution = resolution
        self.bounced = bounced
        self.outcomeSource = .manual
    }

    // Dan sets THIS recipient's conversation state by hand (#650). Also stamps outcomeSource =
    // .manual so isAwaitingFollowUp excludes this recipient from the separate silent follow-up track
    // (mirrors how the lead-level version marks the whole lead .replied to stand down FollowUp's
    // lead-grain sequencer; the per-recipient standdown already exists via that same flag). Declining
    // resolves ONLY this recipient: no cascading suppression of siblings (Dan's 2026-07-08 decision).
    // Orchestrating a resume of this show's other paused-by-reply recipients is Phase 3's job, at the
    // UI-mutation layer, mirroring how ProspectMutations already does that for markContact today; this
    // domain method never reaches into the Prospect or its other recipients.
    func setConversationState(_ state: ConversationState, now: Date) {
        conversationState = state
        markStageReached(state)   // #16: Dan's own call, so it is recorded
        conversationStateSetAt = now
        conversationStateSource = .manual
        outcomeSource = .manual
        if state == .declined {
            resolution = .declinedSoft
        }
    }

    // "Remind me later" for this recipient: step its reminder forward by re-anchoring it, without
    // sending.
    func remindLater(now: Date) {
        conversationRemindedAt = now
    }

    // The AI's auto-classification suggests a state for this recipient (source = auto). Never
    // overwrites a state Dan set by hand.
    func suggestConversationState(_ state: ConversationState, now: Date) {
        guard conversationStateSource != .manual else { return }
        conversationState = state
        conversationStateSetAt = now
        conversationStateSource = .auto
    }

    // Dan accepts a suggestion for this recipient: it becomes his (manual) and the timed reminder
    // clock restarts from now.
    func confirmConversationState(now: Date) {
        guard let state = conversationState else { return }
        markStageReached(state)   // #16: accepting the suggestion makes it his assertion too
        conversationStateSource = .manual
        conversationStateSetAt = now
        conversationRemindedAt = nil
    }

    // Copy-out path (#421): Dan pasted the draft into the Gmail thread he's reading and sent it there
    // himself, so Overture sends nothing. Consume the draft and re-anchor this contact's clock.
    // #431: a "Drafting a reply…" run that has produced nothing after this long is treated as a dead
    // run and surfaced as needs-attention, so a stranded request never sits in progress forever.
    static let replyDraftStallTimeout: TimeInterval = RunTimeouts.replyDraft

    // True when a reply draft was requested, none has landed, and the timeout has elapsed (#431).
    // #471: `runAlive` is the classify run's real heartbeat (ReplyClassifyService.isRunning); when it's
    // still alive, past-timeout no longer counts as stalled, since the wall clock alone can't tell a
    // genuinely dead run from one that's just slower than usual.
    func isReplyDraftStalled(now: Date, timeout: TimeInterval = Recipient.replyDraftStallTimeout, runAlive: Bool = false) -> Bool {
        guard let requested = replyDraftRequestedAt, (replyDraftBody?.isEmpty != false) else { return false }
        return !runAlive && now.timeIntervalSince(requested) >= timeout
    }

    // True when a send was claimed and has run long enough to be considered stuck rather than a
    // normal brief send (#475/#476): the app was interrupted (crash, or a save that never landed)
    // between claiming the send and recording its outcome. Must be surfaced for Dan to check Gmail
    // and resolve by hand: never auto-resent (still not .pending) and never auto-assumed sent.
    func isSendStuck(now: Date, timeout: TimeInterval = RunTimeouts.send) -> Bool {
        guard sendState == .sending, let claimed = sendClaimedAt else { return false }
        return now.timeIntervalSince(claimed) >= timeout
    }

    // Apply Dan's edit to the AI reply draft (#459), mirroring Prospect.applyEdit for the cold draft:
    // his text wins and the deterministic DraftCheck warnings stop nagging on it.
    func applyReplyDraftEdit(_ body: String) {
        // Snapshot the AI reply as the learning baseline on the first substantive edit only, mirroring
        // Prospect.applyEdit; trivial / whitespace saves never overwrite it (#463).
        if originalReplyDraftBody == nil,
           Prospect.isSubstantiveEdit(oldSubject: nil, oldBody: replyDraftBody, newSubject: "", newBody: body) {
            originalReplyDraftBody = replyDraftBody
        }
        replyDraftBody = body
        replyDraftEditedByDan = true
    }

    // Freeze the exact reply body Dan committed (sent or copied out), immune to later re-drafts, as the
    // "sent" side of the voice pair (#463). Mirrors Prospect.freezeSentCopy; only the first commit writes.
    func freezeSentReply(now: Date) {
        guard sentReplyBody == nil, let body = replyDraftBody, !body.isEmpty else { return }
        sentReplyBody = body
        replySentAt = now
    }

    func recordRepliedInGmail(now: Date) {
        freezeSentReply(now: now)   // capture the committed copy before consuming the draft (#463)
        replyDraftSubject = nil
        replyDraftBody = nil
        lastFollowUpAt = now
    }

    // Dan dismissed a wrong auto-detected reply for THIS contact (#219, per-recipient #418): revert
    // the replied state and remember the wrong reply's id so detection never re-flags that same one,
    // while a genuinely newer reply on the contact's thread still gets detected.
    func dismissAutoReply() {
        guard replied else { return }
        replied = false
        repliedAt = nil
        lastReplyText = nil
        dismissedReplyId = lastReplyId
        // The reply is gone, so its derived AI hint + draft must go too (#449); otherwise the
        // contact reads "Awaiting reply" yet still shows an intent suggestion and a leftover draft.
        intentHint = nil
        replyDraftSubject = nil
        replyDraftBody = nil
        replyDraftRequestedAt = nil
        replyDraftEditedByDan = false
        // The reply was wrong, so any half-captured voice pair for it is bogus too (#463).
        originalReplyDraftBody = nil
        sentReplyBody = nil
        replySentAt = nil
    }

    // Dan dismissed a wrong auto-detected bounce for THIS contact (#398): revert bounced and
    // remember the wrong bounce message's id so detection never re-flags that same one, while
    // a genuinely new bounce on the contact's thread still gets detected. Mirrors dismissAutoReply.
    func dismissAutoBounce() {
        guard bounced else { return }
        bounced = false
        dismissedBounceId = lastBounceId
    }
}
