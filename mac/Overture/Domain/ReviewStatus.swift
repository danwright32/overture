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
