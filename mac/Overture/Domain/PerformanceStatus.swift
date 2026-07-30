import Foundation

// Phase F (#424): the single source of truth for a show's performance status, derived from its
// contacts instead of a rolled-up lead field. Booking stays a performance-level fact (the lead
// outcome, or a contact marked booked as attribution); Active vs Lost is read off the contacts.
// Pure and value-typed so the precedence is unit-tested without SwiftData.

// The minimal per-contact facts the rollup needs. Recipient maps to this via `standing`.
struct RecipientStanding: Sendable, Equatable {
    let sendState: SendState
    let resolution: RecipientResolution?
    let bounced: Bool
    // A way to still reach this contact: an email address or a contact form.
    let hasContactPath: Bool

    // In play = an emailed contact still being pursued: a send went out, it hasn't resolved, and it
    // didn't bounce. Covers both "awaiting reply" and "in conversation", both keep the show Active.
    var isInPlay: Bool { sendState == .sent && resolution == nil && !bounced }

    // Contacted = an email actually went out.
    var wasContacted: Bool { sendState == .sent }

    // An un-emailed contact we could still try (the act-then-presenter ladder): keeps a show out of
    // Lost while there is someone left to reach. Dan's call (#424): stay active until all are tried.
    var isUntried: Bool { sendState == .pending && resolution == nil && hasContactPath }
}

enum PerformanceStatus: String, Sendable, Equatable, CaseIterable {
    case new
    case active
    case lostDoorOpen
    case lostNotInterested
    // #1840: Dan stopped working this event. Distinct from `lostDoorOpen` on screen as well as in the
    // data, because a card that said "Closed (not now)" over a show he simply walked away from would be
    // two different facts wearing one sentence (#843).
    case stoodDown
    case booked

    // First match wins: Booked > Active > Lost > New.
    static func derive(_ standings: [RecipientStanding], leadBooked: Bool) -> PerformanceStatus {
        if leadBooked || standings.contains(where: { $0.resolution == .booked }) { return .booked }
        if standings.contains(where: \.isInPlay) { return .active }

        let contacted = standings.filter(\.wasContacted)
        guard !contacted.isEmpty else { return .new }
        // At least one contact emailed and none in play. If there is still a contact left to try, keep
        // the show active (pursue the next one) rather than closing it (#424, Dan's call).
        if standings.contains(where: \.isUntried) { return .active }
        // Nobody left to try: every emailed contact is resolved or bounced. A soft "not now" leaves the
        // door open; otherwise it's a hard close.
        // #1840: ahead of the decline cases, and only when NOTHING was declined. A show whose contacts
        // Dan stopped working reads as stopped; a show where one contact said no and another was stood
        // down is still a decline, because somebody genuinely answered.
        if contacted.allSatisfy({ $0.resolution == .stoodDown || $0.resolution == nil }),
           contacted.contains(where: { $0.resolution == .stoodDown }) { return .stoodDown }
        if contacted.contains(where: { $0.resolution == .declinedSoft }) { return .lostDoorOpen }
        return .lostNotInterested
    }
}

extension Recipient {
    var standing: RecipientStanding {
        let reachable = (email?.isEmpty == false) || (contactFormURL?.isEmpty == false)
        return RecipientStanding(sendState: sendState, resolution: resolution, bounced: bounced,
                                 hasContactPath: reachable)
    }
}

extension PerformanceStatus {
    // The read-only label shown on the review surface now the editable lead outcome picker is gone
    // (#447): a show's status is derived from its contacts, not hand-set at the lead level.
    var label: String {
        switch self {
        case .new: return "New"
        case .active: return "Active"
        case .lostDoorOpen: return "Closed (not now)"
        case .stoodDown: return "Stopped working this"
        case .lostNotInterested: return "Closed (not interested)"
        case .booked: return "Booked"
        }
    }

    // The show's status from its current contacts. Booked stays owned by the lead outcome
    // (DownbeatBooking / a manual booking); this reads it as the top-precedence input.
    static func of(_ prospect: Prospect) -> PerformanceStatus {
        derive(prospect.recipients.map(\.standing), leadBooked: prospect.outcome == .booked)
    }
}
