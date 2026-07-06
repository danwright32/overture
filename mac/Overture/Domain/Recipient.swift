import Foundation
import SwiftData

// Where a recipient came from. `act` = a single-act waterfall result; `performer` = a named
// individual performer on a self-produced show (#587, #366 Phase 2), mutually exclusive with `act`
// per performance (never both used at once); `presenter` = a real presenting org (never the host
// venue); `manual` = an address Dan typed in at approval.
enum RecipientProvenance: String, Codable, CaseIterable, Sendable {
    case act, performer, presenter, manual
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
enum RecipientSuppressionReason: String, Codable, CaseIterable, Sendable {
    case bookedElsewhere, declined
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
    var followUpCount: Int = 0
    var lastFollowUpAt: Date?
    var replied: Bool = false
    var repliedAt: Date?
    var lastReplyId: String?
    var dismissedReplyId: String?
    var lastReplyText: String?
    var bounced: Bool = false
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
         contactFormURL: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
        self.role = role
        self.provenanceRaw = provenance.rawValue
        self.contactMethodRaw = contactMethodRaw
        self.contactConfidenceRaw = contactConfidenceRaw
        self.contactFormURL = contactFormURL
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

    // Sent, no reply, not bounced: the only recipients that receive follow-ups or reminders.
    var isSilent: Bool { sendState == .sent && !replied && !bounced }

    // The contacts the follow-up sequencer may nudge (#418 D): silent AND not hand-resolved. A contact
    // Dan marked Closed/Booked (resolution set) or otherwise judged by hand (outcomeSource == .manual)
    // is still "silent" by the raw definition but must never be nudged again.
    var isAwaitingFollowUp: Bool { isSilent && resolution == nil && outcomeSource != .manual }

    // Ready to actually receive the pitch: still pending and has a real address. A form-only contact
    // (#368) is pending but has no email, so it is never auto-sendable until Dan fills one in. The send
    // queue, the manual-send picker, and the "show fully sent?" rollup all read this one predicate.
    // A contact auto-paused by a reply on the same show (#430) is held back until Dan triages, so it
    // drops out of every send path that reads this predicate.
    var isSendablePending: Bool { sendState == .pending && (email?.isEmpty == false) && !pausedByReply }

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
}
