import Foundation

// #1794: what the Presenters shortlist says about where a row leads. In the domain rather than in the
// view, so the app's words stay in the tested types and land in `docs/copy-inventory.md` (#885).
enum OrganisationsCopy {
    // Said as what the tap DOES, in the order it does it, because both halves are consequences Dan
    // should not have to discover: the sheet goes away, and the queue stops showing everything else.
    // It names the organisation so the sentence is about the row under the pointer rather than about
    // rows in general.
    static func showShowsHelp(_ name: String) -> String {
        "Close this and show only \(name)'s shows in the queue"
    }
}
