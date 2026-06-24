import Foundation

// Where a prospect sits in Dan's review. The scout writes everything as `.new`;
// Dan moves it to `.queued` (keep), the Prep run fills a contact + draft and marks
// it `.drafted` (ready to review), Dan `.approved` it to send, or `.dismissed` a no-go.
// Stored on the model as a raw string so SwiftData keeps it simple.
enum ReviewStatus: String, CaseIterable, Sendable {
    case new
    case queued
    case drafted
    case approved
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

// The reasons Dan can give when dismissing, mirroring the engine's dismiss_reason set.
enum DismissReason: String, CaseIterable, Sendable {
    case dateConflict = "date_conflict"
    case dayDoesntWork = "day_doesnt_work"
    case notInterested = "not_interested"
    case alreadyBooked = "already_booked"
    case duplicate

    var label: String {
        switch self {
        case .dateConflict: return "Date conflict"
        case .dayDoesntWork: return "Day doesn't work"
        case .notInterested: return "Not a fit"
        case .alreadyBooked: return "Already booked"
        case .duplicate: return "Duplicate"
        }
    }
}
