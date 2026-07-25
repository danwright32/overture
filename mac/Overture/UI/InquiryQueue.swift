import Foundation

// Phase 3 (#1436): a hire inquiry as a display row in the daily queue, built without SwiftData so the
// fold-in and the date-window audit are unit-testable. An inquiry carries no fit score, geo, or
// reachability concept (all Prospect-only); it shows its source and its own lifecycle state instead.
struct InquiryRow: Identifiable, Equatable, Sendable {
    let id: String
    let inquirerName: String
    let source: InquirySource
    let eventName: String
    let performanceDate: String?
    let venue: String?
    let outcome: Outcome
    let sentAt: Date?
    let replied: Bool
    let bookingSuggested: Bool
    let followUpNudgeDue: Bool
    let shouldSuggestClosing: Bool
}

// One row of the unified daily list: a scouted show to pitch, or a hire inquiry. The queue groups and
// renders these together; the view switches on the case to draw each kind.
enum QueueRow: Identifiable, Equatable {
    case prospect(QueueItem)
    case inquiry(InquiryRow)

    var id: String {
        switch self {
        case .prospect(let item): return "p:\(item.id)"
        case .inquiry(let row): return "i:\(row.id)"
        }
    }

    // The date the row groups under. An inquiry groups by its event date exactly like a show, but
    // unlike a show it is never DROPPED for that date being past or far out (see combinedQueueRows).
    var performanceDate: String? {
        switch self {
        case .prospect(let item): return item.performanceDate
        case .inquiry(let row): return row.performanceDate
        }
    }
}

// A date section of the unified list, mirroring QueueModel.DateGroup but over QueueRow.
struct RowDateGroup: Identifiable, Equatable {
    let id: String
    let weekday: String
    let monthDay: String
    let year: String
    let rows: [QueueRow]
}
