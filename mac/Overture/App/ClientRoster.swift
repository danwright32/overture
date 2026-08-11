import Foundation
import Observation

// #2365: Dan's Downbeat client list, loaded ONCE for the whole app.
//
// WHY THIS IS OWNED BY THE APP rather than read where it is needed. The list lives in a JSON file on
// disk, and the surfaces that now need it are the queue's render pass and the deep-link routing, both of
// which are on a render path. `QueueRenderPass.Inputs` states the rule in its own words: that pass "may
// not reach the store or the filesystem itself", and it is right to, because a file read on every redraw
// is the shape #1429 and #1356 each had to undo after it froze a sheet.
//
// It is also the honest answer to "who decides who is a client". Before this, exactly one surface (the
// Sources sheet) loaded the roster and everything else did without it. Two surfaces loading it separately
// would be two answers to one question the moment their refreshes fell out of step, which is the shape
// #1570 already cost this app on the geography gate.
//
// DELIBERATELY NOT STORED ON `WatchedSource`. `ClientHorizon`'s own header records why: the automatic
// match "is DERIVED, never stored, so it arms and disarms on its own as clients come and go in Downbeat,
// with no stale forever-flag". Caching the ROSTER in memory keeps that property (a reload re-derives
// every verdict); writing a verdict into the store would not.
@MainActor
@Observable
final class ClientRoster {
    private(set) var clients: [DownbeatClient] = []
    // #1356's lesson, carried rather than dropped: an empty client list from a file that could not be
    // read is not the same fact as an empty list from a file that genuinely holds none, and only one of
    // them should be believed. Held so a surface can say which it is; nothing branches on it yet.
    private(set) var health: DownbeatBridge.Health = .ok
    private(set) var loadedAt: Date?

    // Injected so a test never reaches Dan's real export (L2). The default is the shipped read.
    private let load: (Date) -> (clients: [DownbeatClient], health: DownbeatBridge.Health)

    init(load: @escaping (Date) -> (clients: [DownbeatClient], health: DownbeatBridge.Health) = {
        let loaded = DownbeatBridge.loadWithHealth(now: $0)
        return (loaded.clients, loaded.health)
    }) {
        self.load = load
    }

    func reload(now: Date = Date()) {
        let loaded = load(now)
        clients = DownbeatClient.sortedByName(loaded.clients)
        health = loaded.health
        loadedAt = now
    }

    // The value the stage predicate actually asks. Built here rather than at each call site so the
    // O(clients x sources) match happens once per render pass instead of once per show (#1429).
    func window(for sources: [WatchedSource]) -> ClientWindow {
        ClientWindow(sources: sources, clients: clients)
    }
}
