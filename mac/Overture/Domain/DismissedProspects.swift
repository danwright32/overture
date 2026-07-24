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

    // Undo a dismiss: reason cleared, and (#16) the exit date cleared with it, since the show never
    // actually left.
    //
    // #1414: the ONE un-dismiss implementation, so the Archive's Restore button and Cmd+Z cannot drift
    // apart. They pass different targets deliberately. The button defaults to `.new`, which is what
    // Restore has always meant and the only thing it CAN mean for a show dismissed in an earlier
    // session, since nothing records what that show was before it was cut. Undo passes the status it
    // captured moments earlier, so a show dismissed while it was contacted comes back contacted rather
    // than reappearing as a fresh lead Dan has in fact already emailed.
    static func restore(_ prospect: Prospect, to status: ReviewStatus = .new) {
        prospect.clearDismissal(to: status)
    }
}
