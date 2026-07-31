import Foundation
import Observation

// #1770: the ONE cached answer to "is Gmail connected?".
//
// This used to be `GmailAuthManager.shared.isConnected`, which resolves to GmailCredentials.isConnected,
// which opens the token file and JSON-decodes it. That is a synchronous filesystem read, and it was being
// made inside SwiftUI view bodies: once per queue card, plus once for the pill strip, plus once per access
// of a FollowUpsView computed property. The queue re-renders on every scroll movement, so the same answer
// was re-read from disk for every visible card on every frame. It is one fact about the app, identical for
// every card, and it changes only at moments the app already knows about.
//
// @Observable, so the surfaces reading it re-render when it actually changes rather than because they
// happened to be rebuilt. Refreshed at the transitions in `refresh()`'s call sites: launch (this init), a
// completed OAuth connect, the Debug seed, the periodic reply check, and a send that failed, which is the
// moment a revoked token shows itself. A cached credential that has gone stale is the failure this design
// could introduce, so it is the one GmailConnectionTests pins hardest.
@MainActor
@Observable
final class GmailConnection {
    static let shared = GmailConnection()

    private let load: @MainActor () -> Bool

    private(set) var isConnected: Bool

    init(load: @escaping @MainActor () -> Bool = { GmailCredentials.isConnected }) {
        self.load = load
        self.isConnected = load()
    }

    // Go back to the source. Callers are the state transitions above, never a render path: the whole
    // point of this type is that drawing a card asks the filesystem nothing.
    func refresh() {
        isConnected = load()
    }

    // Refresh and answer in one step, for a caller that must not act on a cached value (a send failing,
    // a background check about to skip). Deliberately NOT the default read: it costs a disk hit.
    @discardableResult
    func refreshedIsConnected() -> Bool {
        refresh()
        return isConnected
    }
}
