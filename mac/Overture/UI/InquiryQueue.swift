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
    // #2145: whether this thread bounced. Carried so the Reply control can refuse the same case the
    // show side already refuses: an answer to an address that has proved dead cannot arrive.
    let bounced: Bool
    let bookingSuggested: Bool
    let followUpNudgeDue: Bool
    let shouldSuggestClosing: Bool
    // #2675: the three send problems an inquiry can carry, none of which had a reader. Kept as three
    // separate facts rather than one "something is wrong" flag, because they ask different things of Dan:
    // a lost thread means an answer will not be noticed at all, a lost message id means only that a nudge
    // arrives as a separate email, and a send error means nothing went out (L53).
    var threadIdDegraded: Bool = false
    var threadingDegraded: Bool = false
    var sendError: String? = nil
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

    // The date the row groups under. An inquiry groups by its event date exactly like a show, and is
    // never DROPPED for that date being past or far out: its stage is decided by whether Dan owes a
    // reply (StageNavigation.stage(for:)), which never looks at the date.
    var performanceDate: String? {
        switch self {
        case .prospect(let item): return item.performanceDate
        case .inquiry(let row): return row.performanceDate
        }
    }
}

// #1513: one row of the Reached-out stage, whichever kind it is. Both carry the SAME date meaning (when
// this next needs Dan), which is what lets them share one grouping and therefore one heading. Before
// this, an inquiry block sat above the "Grouped by when to reach out next" caption carrying its EVENT
// date, so two identical-looking headings in one view answered different questions.
enum ReachedOutEntry: Identifiable {
    case prospect(prospect: Prospect, recipient: Recipient, next: Date)
    // Carries the Inquiry itself, not just its display row: the view needs the model to act on it, and
    // looking it back up by the row's id is unreliable (that id comes from the persistent model id,
    // which is not yet distinct for an unsaved object).
    case inquiry(inquiry: Inquiry, row: InquiryRow, next: Date)

    var next: Date {
        switch self {
        case .prospect(_, _, let next): return next
        case .inquiry(_, _, let next): return next
        }
    }

    var id: String {
        switch self {
        case .prospect(_, let recipient, _): return "p:\(recipient.id)"
        case .inquiry(_, let row, _): return "i:\(row.id)"
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
