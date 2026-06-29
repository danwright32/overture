import Foundation
import SwiftData

// Where a recipient came from. `act` = the performers; `presenter` = a real presenting org (never
// the host venue); `manual` = an address Dan typed in at approval.
enum RecipientProvenance: String, Codable, CaseIterable, Sendable {
    case act, presenter, manual
}

// A recipient's place in sending. Distinct from a performance's review status (ReviewStatus);
// "suppressed" is an unsent send cancelled because the performance froze (any-yes rule).
enum SendState: String, Codable, CaseIterable, Sendable {
    case pending, sent, suppressed
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
    // NOT @Attribute(.unique) — the same act emailed for two performances shares an id, and a unique
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
    var sentAt: Date?
    var gmailThreadId: String?
    var gmailMessageId: String?
    var sendError: String?
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

    // Ready to actually receive the pitch: still pending and has a real address. A form-only contact
    // (#368) is pending but has no email, so it is never auto-sendable until Dan fills one in. The send
    // queue, the manual-send picker, and the "show fully sent?" rollup all read this one predicate.
    var isSendablePending: Bool { sendState == .pending && (email?.isEmpty == false) }

    // Deterministic send order. SwiftData to-many relationships are UNORDERED, so the send queue and
    // the manual-send picker must impose a stable order or "the next recipient" (and which address each
    // click sends) would vary run to run. Act contacts go first, then a presenter, then a manual add
    // (the #366/#368 contact ladder: target the act; the presenter only after), ties broken by id.
    var sendOrderRank: Int {
        switch provenance {
        case .act: return 0
        case .presenter: return 1
        case .manual: return 2
        }
    }

    var firstName: String { Salutation.firstName(name) }

    // Manual-judge outcome marking (#418 B2). Dan hand-sets THIS contact's outcome from the
    // conversation surface, after reading the reply in Gmail. Stamps `outcomeSource = .manual` so
    // per-recipient detection (A2) never overwrites his call — including an "In conversation" mark,
    // which sets the source flag even though it sets no resolution. The locked vocabulary maps onto
    // existing fields with NO new enum: In conversation = (nil, false), Booked = (.booked, false),
    // Closed-not-now = (.declinedSoft, false), Closed-no = (.declinedHard, false), Bounced = (nil, true).
    //
    // ATTRIBUTION ONLY for `.booked`: this attributes the single lead booking to the contact who
    // landed it (`resolution` doc, #389). It does NOT create or count a lead booking and does NOT set
    // `prospect.outcome` — the lead booking stays fully lead-level via DownbeatBooking.reconcileBooked
    // (locked decision g). Phase F's derivation reads `resolution == .booked` for attribution display
    // only; never wire this into the lead booking count.
    func markOutcomeManually(resolution: RecipientResolution?, bounced: Bool = false) {
        self.resolution = resolution
        self.bounced = bounced
        self.outcomeSource = .manual
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
    }
}
