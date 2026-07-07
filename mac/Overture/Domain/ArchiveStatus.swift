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
    case booked
    case dismissed

    var label: String {
        switch self {
        case .new: return "New"
        case .active: return "Active"
        case .lostDoorOpen: return "Closed (not now)"
        case .lostNotInterested: return "Closed (not interested)"
        case .booked: return "Booked"
        case .dismissed: return "Dismissed"
        }
    }

    static func of(_ item: QueueItem) -> ArchiveStatus {
        guard item.status != .dismissed else { return .dismissed }
        switch item.performanceStatus {
        case .new: return .new
        case .active: return .active
        case .lostDoorOpen: return .lostDoorOpen
        case .lostNotInterested: return .lostNotInterested
        case .booked: return .booked
        }
    }
}
