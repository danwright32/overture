import Foundation

// Where a prospect sits in Dan's review. The scout writes everything as `.new`;
// Dan moves it to `.queued` (keep), the Prep run fills a contact + draft and marks
// it `.drafted` (ready to review), Dan `.approved` it to send, the send advances it to
// `.contacted` (the pitch went out, #200), or `.dismissed` a no-go.
// Stored on the model as a raw string so SwiftData keeps it simple.
enum ReviewStatus: String, CaseIterable, Sendable {
    case new
    case queued
    case drafted
    case approved
    case contacted
    case dismissed
}

// How a contact was found, weakest-to-strongest mirrored by its confidence.
enum ContactMethod: String, CaseIterable, Sendable {
    case namedDecisionMaker = "named_decision_maker"
    case genericInbox = "generic_inbox"
    case formOrDM = "form_or_dm"
}

enum ContactConfidence: String, CaseIterable, Sendable {
    case high, medium, low
}

// What ultimately happened after Dan reached out. Defaults to `.noResponse` (like
// Dan's booking sheet) so the majority need no touch. `.replied` can be set
// automatically from Gmail reply detection; `.booked` from Downbeat (the canonical
// booking record). The two lost cases are Dan's call: `.lostSoft` (the door is open
// for the future) and `.lostHard` (not interested), which carry through to the
// prior-relationship ranking. Only meaningful once a prospect was sent; feeds the
// fit-score feedback loop (#4).
enum Outcome: String, CaseIterable, Sendable {
    case noResponse = "no_response"
    case replied
    case booked
    case lostSoft = "lost_soft"
    case lostHard = "lost_hard"

    var label: String {
        switch self {
        case .noResponse: return "No response"
        case .replied: return "Replied"
        case .booked: return "Booked"
        case .lostSoft: return "Lost (keep in mind)"
        case .lostHard: return "Lost (not interested)"
        }
    }

    // Legacy booking rows recorded a single ambiguous "passed"; treat those as the soft
    // lost case (the door stays open) so old data keeps a sensible meaning.
    static func fromStored(_ raw: String) -> Outcome {
        if let o = Outcome(rawValue: raw) { return o }
        if raw == "passed" { return .lostSoft }
        return .noResponse
    }
}

// Where an outcome came from, so an automatic signal (Gmail/Downbeat) never
// overwrites a decision Dan made by hand.
enum OutcomeSource: String, CaseIterable, Sendable {
    case auto      // gmail reply / downbeat booking
    case manual    // Dan marked it
}

// Where an active conversation sits between a bare reply and a booking (#111). The three active
// states get timed, event-aware reminders; `declined` is terminal (it resolves the lead to
// lost-soft). Stored on Prospect as a raw string with an OutcomeSource (auto/manual), so #112's AI
// suggestion never silently overwrites a state Dan set by hand.
enum ConversationState: String, CaseIterable, Sendable {
    case interested
    case wantsToBook = "wants_to_book"
    case hasQuestion = "has_question"
    case declined

    var label: String {
        switch self {
        case .interested: return "Interested"
        case .wantsToBook: return "Wants to book"
        case .hasQuestion: return "Has a question"
        case .declined: return "Declined"
        }
    }

    // The active states (everything but declined) generate reminders.
    var isActive: Bool { self != .declined }
}

// The reasons Dan can give when dismissing, mirroring the engine's dismiss_reason set.
// #864: `wentBy` is the one Overture writes for itself, and the only one that is not a decision at all:
// the show's last night passed while it sat untriaged. It is a fact about the calendar, so it must never
// read as a judgement Dan made (it gets its own Archive bucket, and teaches LocalHistory nothing).
enum DismissReason: String, CaseIterable, Sendable {
    case dateConflict = "date_conflict"
    case dayDoesntWork = "day_doesnt_work"
    case notInterested = "not_interested"
    case dontWantToShoot = "dont_want_to_shoot"   // #351: personal taste, distinct from "Not a fit"
    case alreadyBooked = "already_booked"
    case duplicate
    case wentBy = "went_by"

    var label: String {
        switch self {
        case .dateConflict: return "Date conflict"
        case .dayDoesntWork: return "Day doesn't work"
        case .notInterested: return "Not a fit"
        case .dontWantToShoot: return "Don't want to shoot this"
        case .alreadyBooked: return "Already booked"
        case .duplicate: return "Duplicate"
        case .wentBy: return "Went by"
        }
    }

    // The reasons Dan can pick himself. `wentBy` is Overture's own, never offered as a choice: he cannot
    // decide that a date has passed.
    static var danCanChoose: [DismissReason] { allCases.filter { $0 != .wentBy } }
}
