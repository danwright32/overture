import Testing
import Foundation

// #4115: the client verdict is decided once per CHANGE, not once per render pass.
//
// WHAT WAS MEASURED, and it is the whole reason this suite exists. In a live sample of a window frozen
// for about 85 seconds during a whole-night dismiss (2026-09-21, 4,328 main thread samples at 2ms),
// `ClientHorizon.clientSourceIds(sources:clients:)` carried 586 samples, 13.5%, and its caller was
// `QueueView.makeRenderData()`. That function is one render pass, and #4106 measured the queue being
// rebuilt twice per change and repeatedly during a scout.
//
// THE SHAPE IS THE SAME DEFECT ONE LEVEL UP (L30). #1429 measured `isClient` being asked once per ROW
// while the Sources sheet redrew, and moved it to "decided once instead of per row". The queue then
// began asking that once-per-list answer once per PASS. Moving it again without a guard would leave the
// third level unprotected, so what is asserted here is the CALL COUNT rather than a duration: the
// duration is what varies with store size, and a count is a statement about this code (L63).
//
// WHERE THE FIX LIVES, and why here rather than at the call site. `ClientRoster.window(for:)` is the one
// funnel both readers go through (`QueueView.clientWindow` and `RootView.clientWindow`), so the cache
// sits there and every caller inherits it, present and future. A memo at one call site would have left
// the other paying (L30, L613).
//
// THE TRAP THIS IS DESIGNED AROUND. A cheap key that MISSES a change serves a stale verdict, and a stale
// client verdict is not a cosmetic fault: it decides whether a client's far-out show is inside the lead
// time window at all, so a miss silently drops shows off the queue (L40). The key is therefore built
// from exactly what `ClientHorizon.isClient` reads and nothing cheaper: each source's id, org name and
// manual tag, and each client's display and short names (the two `HistoryMatch.clientNames` returns).
// The four invalidation tests below are one per field that can move.
@MainActor
@Suite("The client window is decided once per change, not once per render pass (#4115)")
struct ClientWindowIsDecidedOncePerChangeTests {

    private static func client(_ name: String, short: String? = nil) -> DownbeatClient {
        DownbeatClient(id: name, displayName: name, shortName: short, email: "", contractEmail: "",
                       phoneNumber: nil, isTaxExempt: nil, hasLeftReview: false, specialBehaviors: [],
                       notes: nil, hostingSite: "")
    }

    private static func source(_ org: String, tag: Bool? = nil) -> WatchedSource {
        let s = WatchedSource(sourceId: org, orgName: org, listingsURL: "https://\(org).example/e", kind: .html)
        s.clientTagOverride = tag
        return s
    }

    private static func roster(_ clients: [DownbeatClient]) -> ClientRoster {
        let roster = ClientRoster(load: { _ in (clients, .ok) })
        roster.reload(now: Date(timeIntervalSince1970: 1_700_000_000))
        return roster
    }

    private static let clients = [client("Brooklyn Youth Chorus"), client("New York Youth Symphony", short: "NYYS")]
    private static func sources() -> [WatchedSource] {
        [source("Brooklyn Youth Chorus"), source("Some Random Venue"), source("Another Room")]
    }

    // THE POSITIVE CONTROL, first, because every assertion below is a count going to zero and a zero
    // proves nothing until something has been seen to produce a non-zero (L159, L1). If deciding the
    // window ever stops running name matches for its own reasons, this goes red and says so rather than
    // letting the real assertions pass by accident.
    @Test("deciding the window from scratch runs the fuzzy match, so a zero below is a measured zero")
    func decidingTheWindowCostsNameMatches() {
        let roster = Self.roster(Self.clients)
        let sources = Self.sources()
        let tally = QueueRenderPass.WorkTally.measure { _ = roster.window(for: sources) }
        #expect(tally.clientNameMatches > 0, Comment(rawValue:
            "deciding the client window ran no name matches at all, so every count assertion in this "
            + "suite is measuring nothing"))
    }

    @Test("a second read with nothing changed runs no name matches at all")
    func aSecondReadIsFree() {
        let roster = Self.roster(Self.clients)
        let sources = Self.sources()
        _ = roster.window(for: sources)
        let tally = QueueRenderPass.WorkTally.measure { _ = roster.window(for: sources) }
        #expect(tally.clientNameMatches == 0, Comment(rawValue:
            "reading the client window a second time with nothing changed ran "
            + "\(tally.clientNameMatches) name matches, so the queue pays the O(sources x clients) "
            + "fuzzy match once per render pass (#4115)"))
    }

    // And the answer it serves is the authority's, not a cheaper approximation of it (L70).
    @Test("the cached answer is the one the authority would give")
    func theCachedAnswerMatchesTheAuthority() {
        let roster = Self.roster(Self.clients)
        let sources = Self.sources()
        let fresh = ClientWindow(sources: sources, clients: Self.clients)
        _ = roster.window(for: sources)
        #expect(roster.window(for: sources) == fresh)
        #expect(fresh.clientSourceIds == ["Brooklyn Youth Chorus"])
    }

    // One test per field the key must see. Each asserts the VERDICT moved, not merely that work ran,
    // because a key that invalidates without changing the answer would pass a count assertion.
    @Test("renaming a source re-decides the window")
    func aRenamedSourceIsRedecided() {
        let roster = Self.roster(Self.clients)
        let sources = Self.sources()
        #expect(roster.window(for: sources).clientSourceIds == ["Brooklyn Youth Chorus"])
        sources[1].orgName = "New York Youth Symphony"
        #expect(roster.window(for: sources).clientSourceIds == ["Brooklyn Youth Chorus", "Some Random Venue"])
    }

    @Test("tagging a source re-decides the window")
    func aTaggedSourceIsRedecided() {
        let roster = Self.roster(Self.clients)
        let sources = Self.sources()
        #expect(roster.window(for: sources).clientSourceIds == ["Brooklyn Youth Chorus"])
        sources[2].clientTagOverride = true
        #expect(roster.window(for: sources).clientSourceIds == ["Brooklyn Youth Chorus", "Another Room"])
    }

    @Test("adding a watched source re-decides the window")
    func anAddedSourceIsRedecided() {
        let roster = Self.roster(Self.clients)
        var sources = Self.sources()
        #expect(roster.window(for: sources).clientSourceIds == ["Brooklyn Youth Chorus"])
        sources.append(Self.source("New York Youth Symphony"))
        #expect(roster.window(for: sources).clientSourceIds
                == ["Brooklyn Youth Chorus", "New York Youth Symphony"])
    }

    // The roster half. A client added in Downbeat must widen the window without a relaunch, which is
    // exactly what `ClientRosterWiringTests` says the export-change reload is for: a cache that could not
    // see a reload would silently undo that wiring.
    @Test("reloading the roster with a new client re-decides the window")
    func aReloadedRosterIsRedecided() {
        var loaded = [Self.client("Brooklyn Youth Chorus")]
        let roster = ClientRoster(load: { _ in (loaded, .ok) })
        roster.reload(now: Date(timeIntervalSince1970: 1_700_000_000))
        let sources = Self.sources()
        #expect(roster.window(for: sources).clientSourceIds == ["Brooklyn Youth Chorus"])
        loaded.append(Self.client("Another Room"))
        roster.reload(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(roster.window(for: sources).clientSourceIds == ["Brooklyn Youth Chorus", "Another Room"],
                Comment(rawValue:
                    "a client added in Downbeat did not widen the window after a reload, so the cache "
                    + "outlived the fact it was derived from (L40)"))
    }

    // A client RENAMED rather than added, because the count and the identities are both unchanged and a
    // key built from either alone would miss it.
    @Test("renaming a client re-decides the window")
    func aRenamedClientIsRedecided() {
        var loaded = [Self.client("Brooklyn Youth Chorus")]
        let roster = ClientRoster(load: { _ in (loaded, .ok) })
        roster.reload(now: Date(timeIntervalSince1970: 1_700_000_000))
        let sources = Self.sources()
        #expect(roster.window(for: sources).clientSourceIds == ["Brooklyn Youth Chorus"])
        loaded = [Self.client("Another Room")]
        roster.reload(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(roster.window(for: sources).clientSourceIds == ["Another Room"])
    }

    // A client given a SHORT NAME that matches a source, with the display name unchanged. `clientNames`
    // returns both, so a key carrying only the display name would serve a stale verdict here.
    @Test("giving a client a short name re-decides the window")
    func aClientShortNameIsRedecided() {
        var loaded = [Self.client("Youth Symphony of New York")]
        let roster = ClientRoster(load: { _ in (loaded, .ok) })
        roster.reload(now: Date(timeIntervalSince1970: 1_700_000_000))
        let sources = [Self.source("Another Room")]
        #expect(roster.window(for: sources).clientSourceIds.isEmpty)
        loaded = [Self.client("Youth Symphony of New York", short: "Another Room")]
        roster.reload(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(roster.window(for: sources).clientSourceIds == ["Another Room"])
    }
}
