import Foundation

// Where a show sits for the Archive lookup. Mirrors PerformanceStatus's five outcomes, plus
// Dismissed (a triage stage cut, ReviewStatus.dismissed) as a sixth, mutually exclusive bucket.
// Dismissed takes precedence: a cut prospect is always performanceStatus .new (it was never
// contacted), but that is not the useful lens once Dan has cut it.
enum ArchiveStatus: String, CaseIterable, Sendable {
    case new
    case active
    case lostDoorOpen
    case lostNotInterested
    // #1840: a show Dan stopped working. Its own bucket for the same reason it is its own contact
    // state: it is not a close somebody else decided, and burying it among the ones that were would
    // make his own walk-aways unfindable and uncountable.
    case stoodDown
    case booked
    case dismissed
    // #864: a show whose last night passed while it sat untriaged. Overture retired it; Dan never
    // decided anything. Its own bucket, because Dismissed means "I cut this", and it is also where he
    // goes to undo a cut he made by mistake (#28). Filling that list with shows he never even looked at
    // would bury the one he is actually looking for.
    case wentBy

    var label: String {
        switch self {
        case .new: return "New"
        case .active: return "Active"
        case .lostDoorOpen: return "Closed (not now)"
        case .lostNotInterested: return "Closed (not interested)"
        case .stoodDown: return "Stopped working"
        case .booked: return "Booked"
        case .dismissed: return "Dismissed"
        case .wentBy: return "Went by"
        }
    }

    static func of(_ item: QueueItem) -> ArchiveStatus {
        // Checked before .dismissed: a retired show IS stored as dismissed (that is how it leaves the
        // queue and stops being counted), and its reason is the only thing that distinguishes it.
        if item.showOutcome == .wentBy { return .wentBy }
        guard item.status != .dismissed else { return .dismissed }
        switch item.performanceStatus {
        case .new: return .new
        case .active: return .active
        case .lostDoorOpen: return .lostDoorOpen
        case .lostNotInterested: return .lostNotInterested
        case .stoodDown: return .stoodDown
        case .booked: return .booked
        }
    }
}

// #1580: which status chips Archive opens on. Normally the two Dan works from, but an Archive opened
// by the search bar's "Look in Archive" jump has to SHOW him the matches it just counted, and the
// shows the narrowed bar can no longer find are precisely the ones outside those two chips. Opening
// on the usual pair would land him on an empty list one keystroke after being told there were three.
//
// Out of the view, which cannot be tested at all, and next to the type it decides over.
enum ArchiveOpening {
    static let defaultStatuses: Set<ArchiveStatus> = [.new, .active]

    static func statuses(forQuery query: String) -> Set<ArchiveStatus> {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultStatuses : Set(ArchiveStatus.allCases)
    }
}
