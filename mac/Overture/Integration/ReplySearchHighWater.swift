import Foundation

// #2713: how far through the mailbox the reply search has already read.
//
// Without it every tick re-reads the whole window from the oldest live pitch, every thirty minutes,
// for as long as that pitch stays open. With it a tick reads only what has arrived since the last one,
// which is what makes a search over "everything inbound" affordable at all.
//
// In UserDefaults rather than the store, deliberately: it is a fact about the MAILBOX, not about any
// prospect or contact, and there is exactly one of it. Putting it on a row would give it as many copies
// as there are rows and no answer to which one is right (L83). Its reader is
// `ReplySearchScope.windowStart`; nothing else consults it.
enum ReplySearchHighWater {
    static let key = "replySearchSearchedThroughAt"

    // Nil when the mailbox has never been read, which is deliberately not the same as having been read
    // and found empty: the first is a window back to each pitch, the second is a window since the mark.
    static func searchedThrough(from defaults: UserDefaults = .standard) -> Date? {
        let seconds = defaults.double(forKey: key)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    // Monotonic, and that is the guard rather than a nicety. The mark is the newest message a tick
    // actually EXAMINED, and a tick that examined fewer messages than the last one (a truncated run, a
    // narrower window, a clock that stepped back) would otherwise move it backwards and re-read mail
    // already answered for. It can never move forwards past unexamined mail either, because the caller
    // only ever hands it what it read.
    static func record(_ examinedThrough: Date, into defaults: UserDefaults = .standard) {
        if let existing = searchedThrough(from: defaults), examinedThrough <= existing { return }
        defaults.set(examinedThrough.timeIntervalSince1970, forKey: key)
    }
}
