import Foundation

// Where a show sits for the Archive lookup: the show's OWN status, plus two buckets that are not a
// show status at all.
//
// #1841: the show statuses are carried whole rather than restated. This used to be a flat list that
// named each of PerformanceStatus's outcomes a second time, with `of(_:)` mapping one onto the other
// case by case, so adding a status meant the same edit in two files. Nothing enforced the second
// edit except an exhaustive switch, which stops enforcing anything the moment somebody writes a
// `default:` to clear the compile error: the new status then lands silently in whichever bucket the
// default names, and every show in it is unfindable behind a chip that says something else (L41).
// Now there is one list. A status added to PerformanceStatus gets its Archive chip for free.
enum ArchiveStatus: Hashable, Sendable {
    // The show's own status, carried whole. Every outcome PerformanceStatus has is an Archive bucket,
    // including #1840's `stoodDown`, which stays as findable and countable as the closes somebody else
    // decided rather than being buried among them.
    case show(PerformanceStatus)
    // A triage stage cut (ReviewStatus.dismissed). Takes precedence over the show status: a cut
    // prospect is always performanceStatus .new (it was never contacted), but that is not the useful
    // lens once Dan has cut it.
    case dismissed
    // #864: a show whose last night passed while it sat untriaged. Overture retired it; Dan never
    // decided anything. Its own bucket, because Dismissed means "I cut this", and it is also where he
    // goes to undo a cut he made by mistake (#28). Filling that list with shows he never even looked at
    // would bury the one he is actually looking for.
    case wentBy

    var label: String {
        switch self {
        // The one place the chip's words differ from the card's. PerformanceStatus says "Stopped
        // working this", which reads as a sentence about the show in front of him; a filter chip has
        // no show to point at.
        case .show(.stoodDown): return "Stopped working"
        case .show(let status): return status.label
        case .dismissed: return "Dismissed"
        case .wentBy: return "Went by"
        }
    }

    static func of(_ item: QueueItem) -> ArchiveStatus {
        // Checked before .dismissed: a retired show IS stored as dismissed (that is how it leaves the
        // queue and stops being counted), and its reason is the only thing that distinguishes it.
        if item.showOutcome == .wentBy { return .wentBy }
        guard item.status != .dismissed else { return .dismissed }
        return .show(item.performanceStatus)
    }
}

extension ArchiveStatus: CaseIterable {
    // Hand-written because an enum with an associated value gets no synthesized `allCases`, but the
    // show half is still DERIVED from PerformanceStatus rather than listed: this is the one line that
    // has to be right, instead of one line per status. The order is PerformanceStatus's own, so the
    // chips read in the order a show moves through them, with Overture's own two last.
    static let allCases: [ArchiveStatus] =
        PerformanceStatus.allCases.map(ArchiveStatus.show) + [.dismissed, .wentBy]
}

// #1580: which status chips Archive opens on. Normally the two Dan works from, but an Archive opened
// by the search bar's "Look in Archive" jump has to SHOW him the matches it just counted, and the
// shows the narrowed bar can no longer find are precisely the ones outside those two chips. Opening
// on the usual pair would land him on an empty list one keystroke after being told there were three.
//
// Out of the view, which cannot be tested at all, and next to the type it decides over.
enum ArchiveOpening {
    static let defaultStatuses: Set<ArchiveStatus> = [.show(.new), .show(.active)]

    static func statuses(forQuery query: String) -> Set<ArchiveStatus> {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultStatuses : Set(ArchiveStatus.allCases)
    }
}
