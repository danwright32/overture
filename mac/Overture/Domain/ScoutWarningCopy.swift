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
    // #1539: an established source comes back empty in one of two ways, and this used to explain both as
    // the first.
    //
    // Measured on the live store after Dan's 2026-07-26 10:08 scout, the run that produced this popup:
    // The Players Theatre, baseline 153, readable 0, DROPPED 149. The page was read fine and listed 149
    // shows; every one was dropped for having no venue (#1529). The warning said "Its page format may
    // have changed" while the same run had recorded the 149 on that row, so it named a cause that was
    // not true and sent Dan to inspect a page that was correct (L11).
    //
    // The two are told apart by data the run already has, so each gets its own sentence, and a run that
    // produced both says both rather than picking one and being wrong about the rest.
    static func silentlyEmptyFeed(orgNames: [String]) -> String {
        silentlyEmptyFeed(sources: orgNames.map { ($0, 0) })
    }

    static func silentlyEmptyFeed(sources: [(orgName: String, droppedRowCount: Int)]) -> String {
        let readNothing = sources.filter { $0.droppedRowCount == 0 }.map(\.orgName)
        let droppedEverything = sources.filter { $0.droppedRowCount > 0 }

        var parts: [String] = []

        if !readNothing.isEmpty {
            let list = readNothing.joined(separator: ", ")
            parts.append(readNothing.count == 1
                ? "\(list) has listed shows before and came back with nothing this run. Its page format may have changed."
                : "\(readNothing.count) sources have listed shows before and came back with nothing this run: \(list). Their page formats may have changed.")
        }

        for source in droppedEverything {
            let shows = source.droppedRowCount == 1 ? "1 show" : "\(source.droppedRowCount) shows"
            parts.append("\(source.orgName) listed \(shows) this run and every one was dropped, so its page is being read fine. Open Sources to see why they were dropped.")
        }

        return parts.joined(separator: " ")
    }

    static func unqueued(ids: [String]) -> String {
        let list = ids.joined(separator: ", ")
        return ids.count == 1
            ? "The run returned results under a source it was never asked about (\(list)), so it rebuilt an id and that work was ignored. The source it should have belonged to will be read again."
            : "The run returned results under \(ids.count) sources it was never asked about (\(list)), so it rebuilt those ids and that work was ignored. The sources they should have belonged to will be read again."
    }
}
