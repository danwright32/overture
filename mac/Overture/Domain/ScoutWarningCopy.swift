import Foundation

// #1027: the sentences a warning can say that are NOT tied to one source, written once.
//
// They already existed, inline, inside ScoutService.Outcome.warning, where the old single-string alert
// read them. The new sectioned popup renders the same warnings, and it must say them in the SAME words:
// two copies would be one edit away from disagreeing, and the copy inventory would show two lines where
// Dan hears one. So the strings live here, and both the old warning string and the new popup read them.
enum ScoutWarningCopy {
    static let saveFailed =
        "The scout ran but couldn't save its results. Run it again; if this keeps happening, something's wrong with the local store."

    static let silentlyEmptyFeed =
        "The scout reached the calendar feed but found no upcoming events. That's unusual for a 90-day window. The feed's data format may have changed."

    static func unqueued(ids: [String]) -> String {
        let list = ids.joined(separator: ", ")
        return ids.count == 1
            ? "The run returned results under a source it was never asked about (\(list)), so it rebuilt an id and that work was ignored. The source it should have belonged to will be read again."
            : "The run returned results under \(ids.count) sources it was never asked about (\(list)), so it rebuilt those ids and that work was ignored. The sources they should have belonged to will be read again."
    }
}
