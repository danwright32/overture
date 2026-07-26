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

    // #1531: NAMES the calendar that went quiet, because that is the only actionable fact in the warning
    // and the run has always known it. It used to name nothing ("the scout reached the calendar feed"),
    // leaving Dan to work out which of 62 sources it meant, and it used to explain the surprise with a
    // 90-day window. That was Carnegie's Algolia index horizon (WatchedSourceBackfill), written when
    // Carnegie was the only source with a baseline; shown for any other source it was a number about none
    // of them, and it was not the app's own horizon either (a month plus three).
    static func silentlyEmptyFeed(orgNames: [String]) -> String {
        let list = orgNames.joined(separator: ", ")
        return orgNames.count == 1
            ? "\(list) has listed shows before and came back with nothing this run. Its page format may have changed."
            : "\(orgNames.count) sources have listed shows before and came back with nothing this run: \(list). Their page formats may have changed."
    }

    static func unqueued(ids: [String]) -> String {
        let list = ids.joined(separator: ", ")
        return ids.count == 1
            ? "The run returned results under a source it was never asked about (\(list)), so it rebuilt an id and that work was ignored. The source it should have belonged to will be read again."
            : "The run returned results under \(ids.count) sources it was never asked about (\(list)), so it rebuilt those ids and that work was ignored. The sources they should have belonged to will be read again."
    }
}
