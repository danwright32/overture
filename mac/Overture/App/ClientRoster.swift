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
    //
    // #4115: and now once per CHANGE rather than once per pass, which is the same defect one level up.
    // #1429 moved this off the per-ROW path; the queue then began asking it once per render pass, and a
    // live sample of a frozen window (2026-09-21) put `ClientHorizon.clientSourceIds` at 13.5% of the
    // main thread with `QueueView.makeRenderData()` as its caller. A pass runs on every store change and
    // #4106 measures two of them per change, so the roster was re-matched repeatedly for an answer that
    // moves only when a source or the Downbeat roster does.
    //
    // THE CACHE LIVES HERE, in the one funnel both readers go through (`QueueView.clientWindow` and
    // `RootView.clientWindow`), so a caller cannot arrive at the expensive path by not knowing about a
    // memo, and a third caller added later inherits it (L30, L613).
    func window(for sources: [WatchedSource]) -> ClientWindow {
        let wanted = WindowKey(sources: sources, clients: clients)
        if let cachedKey, cachedKey == wanted, let cachedWindow { return cachedWindow }
        let window = ClientWindow(sources: sources, clients: clients)
        cachedKey = wanted
        cachedWindow = window
        return window
    }

    // The exact inputs `ClientHorizon.isClient` reads, and nothing cheaper.
    //
    // A cheap key that MISSES a change here is not a cosmetic fault: the window decides whether a past
    // client's far-out show is inside the lead time window at all, so a stale verdict drops shows off the
    // queue silently (L40). So this carries every field the verdict is derived from rather than a count,
    // an identity hash or a load stamp, each of which is blind to one of the four ways it can move
    // (`ClientWindowIsDecidedOncePerChangeTests` has one test per way).
    //
    // Compared BY VALUE rather than hashed, because a hash collision here shows the wrong shows and the
    // saving a hash would buy is nothing: this builds a handful of small structs over about 74 sources
    // and a few dozen clients, against a token-set fuzzy match over every pairing of the two.
    private struct WindowKey: Equatable {
        struct SourceFacet: Equatable {
            let id: String
            let orgName: String
            let clientTag: Bool?
        }
        struct ClientFacet: Equatable {
            let displayName: String
            let shortName: String?
        }
        let sources: [SourceFacet]
        let clients: [ClientFacet]

        init(sources: [WatchedSource], clients: [DownbeatClient]) {
            // In the order they arrive, not sorted: the verdict is a set keyed by `sourceId`, so a
            // reorder cannot change the answer, and sorting to prove that would cost more than the
            // occasional rebuild a reorder provokes.
            self.sources = sources.map {
                SourceFacet(id: $0.sourceId, orgName: $0.orgName, clientTag: $0.clientTagOverride)
            }
            // Exactly the two names `HistoryMatch.clientNames` returns, which is the whole of what the
            // match reads off a client. The id is deliberately absent: it is not consulted, and carrying
            // it would rebuild on a re-keyed export that matches identically.
            self.clients = clients.map { ClientFacet(displayName: $0.displayName, shortName: $0.shortName) }
        }
    }

    // `@ObservationIgnored` on both, and it is load bearing twice over. These are written DURING a view's
    // body evaluation (that is where `window(for:)` is read from), and an observed write there is the
    // "Modifying state during view update" fault that turns a memo into a redraw loop. It also costs
    // nothing in invalidation: building the key above READS `clients`, which is observed, so a reload
    // still invalidates every view that asked, exactly as it did before this cache existed.
    @ObservationIgnored private var cachedKey: WindowKey?
    @ObservationIgnored private var cachedWindow: ClientWindow?
}
