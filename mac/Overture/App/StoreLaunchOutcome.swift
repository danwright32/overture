import Foundation

// Classifies why a launching Overture process can or cannot run against the local store, so the three
// cases get three DIFFERENT behaviours instead of collapsing onto one degraded screen (#1160).
//
// The bug: `overture` (build-install.sh --launch) reliably left TWO instances running. The login agent
// starts the resident copy (it wins the store's single-writer lock); then `open overture://show` raced
// in before the resident had registered with LaunchServices, so LaunchServices launched a SECOND copy
// instead of routing the URL to the first (LSMultipleInstancesProhibited, #1123, only routes to an
// already-registered instance). The second copy loses the lock and used to linger on the "data is
// unavailable" screen. A duplicate must instead DEFER to the resident and terminate, so two live
// instances are impossible however a duplicate gets spawned.
//
// Only the lock-loss case is a duplicate. A store that opened badly (a foreign database at the path,
// #663, or an open failure) genuinely needs the StoreUnavailableView and must NEVER be mistaken for a
// duplicate and silently terminated, which would hide the real problem behind an app that just vanishes.
enum StoreLaunchOutcome: Equatable {
    case ready                       // holds the lock and the store opened: run normally
    case duplicateInstance           // another live copy holds the lock: defer to it and terminate
    case unavailable(reason: String) // holds the lock but the store is unusable: show the degraded screen

    // The single source of the generic degraded-state message, used when no more specific reason is
    // known. OvertureApp's degraded branch references this too, so the sentence lives in exactly one
    // place instead of being duplicated (which the copy inventory flags as drift, #843).
    static let defaultUnavailableReason = "Overture's data is unavailable."

    // lockAcquired: did THIS process take the single-writer lock (false => another copy holds it).
    // storeOpened:  did the store container open (only meaningful when lockAcquired is true).
    // reason:       the degraded-state message when the store couldn't open.
    static func classify(lockAcquired: Bool, storeOpened: Bool, reason: String?) -> StoreLaunchOutcome {
        guard lockAcquired else { return .duplicateInstance }
        if storeOpened { return .ready }
        return .unavailable(reason: reason ?? defaultUnavailableReason)
    }
}
