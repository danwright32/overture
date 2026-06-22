import Foundation

// Where a prospect sits in Dan's review. The scout writes everything as `.new`;
// Dan moves it to `.queued` (keep, will be drafted) or `.dismissed` (a no-go).
// Stored on the model as a raw string so SwiftData keeps it simple.
enum ReviewStatus: String, CaseIterable, Sendable {
    case new
    case queued
    case dismissed
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
