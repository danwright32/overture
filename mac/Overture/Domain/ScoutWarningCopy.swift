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

    // #2758 / #2999: says what was left out and why it was left out on purpose.
    //
    // The alternative is what used to happen: the scout could not tell a key nobody holds from a store
    // that would not answer, and wrote anyway, which merges two shows into one row and takes a card's
    // keep decision, its contacts and its outreach record with it. Leaving the show out costs one run;
    // that costs the card. So this reads as a deliberate choice rather than a fault, and names the one
    // thing Dan can do about it.
    static func storeUnreadable(count: Int) -> String {
        count == 1
            ? "One show was left out of this run. The local store stopped answering, so Overture could not "
                + "tell whether it was a new show or a card you have already decided on, and it would "
                + "rather skip it than write over one. Run the scout again to pick it up."
            : "\(count) shows were left out of this run. The local store stopped answering, so Overture "
                + "could not tell whether they were new shows or cards you have already decided on, and it "
                + "would rather skip them than write over one. Run the scout again to pick them up."
    }

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

    // #3071: the run read less of the store than it holds, so what it produced is thinner than it looks.
    //
    // Deliberately NOT worded as a failure of the run: nothing was dropped and no show was lost, which is
    // why these reads were not made to throw. What Dan needs is that this run's judgements were made
    // against less than the whole picture, and which part was missing, because the answer differs by
    // read: a missing watchlist means it scanned nothing, a missing venue list means it matched loosely.
    // Running it again is the whole remedy, and it is the only thing named.
    static func degradedReads(_ labels: [String]) -> String {
        let list = labels.joined(separator: ", ")
        return labels.count == 1
            ? "The scout couldn't read \(list), so this run judged against less than Overture actually "
                + "holds. Nothing was lost. Run it again to get the full picture."
            : "The scout couldn't read \(labels.count) parts of its own store (\(list)), so this run "
                + "judged against less than Overture actually holds. Nothing was lost. Run it again to "
                + "get the full picture."
    }

    static func unqueued(ids: [String]) -> String {
        let list = ids.joined(separator: ", ")
        return ids.count == 1
            ? "The run returned results under a source it was never asked about (\(list)), so it rebuilt an id and that work was ignored. The source it should have belonged to will be read again."
            : "The run returned results under \(ids.count) sources it was never asked about (\(list)), so it rebuilt those ids and that work was ignored. The sources they should have belonged to will be read again."
    }
}
