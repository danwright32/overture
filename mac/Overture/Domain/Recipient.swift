import Foundation

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
// holds one or more of these (stored as a JSON blob on Prospect, like rejectedBookingIdsRaw). Each
// carries its own send + engagement state so reply detection, follow-ups, and reminders are
// per-recipient, while booking and the one draft stay on the performance.
struct Recipient: Codable, Equatable, Sendable {
    // Identity + contact. `id` is the canonicalized email when there is one, otherwise the contact
    // form URL (a form-only act, #368), so the SAME recipient is kept when Dan fills in an email
    // later. `email` is nil for a form-only contact until Dan adds one.
    var id: String
    var email: String?
    var name: String?
    var role: String?
    var provenanceRaw: String
    var contactMethodRaw: String?
    var contactConfidenceRaw: String?
    var contactFormURL: String?

    // Per-recipient send + engagement.
    var sendStateRaw: String
    var sentAt: Date?
    var gmailThreadId: String?
    var gmailMessageId: String?
    var sendError: String?
    var followUpCount: Int
    var lastFollowUpAt: Date?
    var replied: Bool
    var repliedAt: Date?
    var lastReplyId: String?
    var dismissedReplyId: String?
    var lastReplyText: String?
    var bounced: Bool
    var resolutionRaw: String?

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
        self.sendStateRaw = SendState.pending.rawValue
        self.sentAt = nil
        self.gmailThreadId = nil
        self.gmailMessageId = nil
        self.sendError = nil
        self.followUpCount = 0
        self.lastFollowUpAt = nil
        self.replied = false
        self.repliedAt = nil
        self.lastReplyId = nil
        self.dismissedReplyId = nil
        self.lastReplyText = nil
        self.bounced = false
        self.resolutionRaw = nil
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

    // Sent, no reply, not bounced: the only recipients that receive follow-ups or reminders.
    var isSilent: Bool { sendState == .sent && !replied && !bounced }

    var firstName: String { Salutation.firstName(name) }
}
