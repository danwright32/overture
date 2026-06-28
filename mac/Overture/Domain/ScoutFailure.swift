import Foundation

// How a scout failure should be shown (#77). A manual run failed after Dan clicked, so a
// modal is expected; an automatic scheduled run failing should be quiet (a status line),
// not a surprise dialog when he opens the app.
enum ScoutFailure {
    // Every error that reaches the scout's catch comes from fetching the calendar feed (the
    // only throwing step), so it is a connectivity/service problem, never an empty result.
    // Say that plainly so a broken feed (e.g. a rotated key) isn't mistaken for a quiet week.
    // A scheduled run stays a quiet status line (#77); a manual run gets the modal Dan expects,
    // with the technical detail kept for diagnosis. #126.
    static func presentation(auto: Bool, message: String) -> (alert: String?, status: String?) {
        if auto {
            return (nil, "Auto-scout couldn't reach the calendar feed (a connection or service problem, not a quiet week). It'll try again later.")
        }
        let alert = "Couldn't reach Carnegie's calendar feed. This is a connection or service problem, not a quiet week. Check your internet and run the scout again. If it keeps failing, the feed's data source may have changed.\n\nDetails: \(message)"
        return (alert, nil)
    }
}
