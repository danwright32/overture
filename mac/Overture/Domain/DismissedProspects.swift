import Foundation

// Dismissed prospects drop out of the queue; this is how Dan reviews them and undoes a
// mistaken cut (#28). Pure list + restore so the logic is testable without SwiftData.
enum DismissedProspects {
    // Only the dismissed ones, most-recently-touched first (ingestedAt as the stand-in
    // for "when it was last acted on").
    static func list(from all: [Prospect]) -> [Prospect] {
        all.filter { $0.status == .dismissed }
           .sorted { $0.ingestedAt > $1.ingestedAt }
    }

    // Undo a dismiss: back to an undecided candidate in the queue, reason cleared.
    static func restore(_ prospect: Prospect) {
        prospect.status = .new
        prospect.dismissReasonRaw = nil
    }
}
