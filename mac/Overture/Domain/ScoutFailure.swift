import Foundation

// How a scout failure should be shown (#77). A manual run failed after Dan clicked, so a
// modal is expected; an automatic scheduled run failing should be quiet (a status line),
// not a surprise dialog when he opens the app.
enum ScoutFailure {
    static func presentation(auto: Bool, message: String) -> (alert: String?, status: String?) {
        if auto {
            return (nil, "Auto-scout couldn't reach the venue calendar just now. It'll try again later.")
        }
        return (message, nil)
    }
}
