import Foundation

// How a scout failure should be shown (#77). A manual run failed after Dan clicked, so a
// modal is expected; an automatic scheduled run failing should be quiet (a status line),
// not a surprise dialog when he opens the app.
enum ScoutFailure {
    // #802: this is no longer "a source could not be reached". A single source failing is now a NAMED,
    // typed failure on that source's row, counted into the outcome and reported by org name every run
    // (see ScoutService.Outcome.warning), and the run carries on to the other sources. It used to throw,
    // which was correct when there was exactly one source and its failure meant the run had nothing left
    // to do; with a watchlist, throwing would mean source 9 being down silently costs Dan sources 10
    // through 20.
    //
    // What reaches this catch is a failure that killed the WHOLE run: the store went away, or something
    // unforeseen. So the copy no longer names Carnegie, because it is no longer about a calendar feed.
    //
    // A scheduled run stays a quiet status line (#77); a manual run gets the modal Dan expects after
    // clicking, with the technical detail kept for diagnosis (#126).
    static func presentation(auto: Bool, message: String) -> (alert: String?, status: String?) {
        if auto {
            return (nil, "The scheduled scout couldn't run. It'll try again later.")
        }
        let alert = "The scout couldn't run. This stopped the whole run, so no source was checked. Try again; if it keeps failing, something is wrong with the local store rather than with any one calendar.\n\nDetails: \(message)"
        return (alert, nil)
    }
}
