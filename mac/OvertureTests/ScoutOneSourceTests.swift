import Testing
import Foundation

// Reading ONE source on demand. Two reasons it exists, and the second is the durable one.
//
// Today: 37 of 38 sources have never been read, and every source shares the same lastCheckedAt (the
// daily run checks them in one pass), so the oldest-first order is a tie across the whole list and a
// budget picks arbitrarily. There is no way to say "read THIS one", which is exactly what is needed to
// try a new extract instruction on a known-hard page rather than on three sources drawn by lot.
//
// Afterwards: add a source and read it immediately instead of waiting for a full scout; re-read one
// whose results looked wrong. Both without spending a run on the other 37.

@MainActor
private func source(_ id: String, checkedAt: Date? = Date(timeIntervalSince1970: 1_000_000)) -> WatchedSource {
    let s = WatchedSource(sourceId: id, orgName: id, listingsURL: "https://example.com/\(id)", kind: .html)
    s.lastCheckedAt = checkedAt
    return s
}

@MainActor
@Suite("Scout one source")
struct ScoutOneSourceTests {
    // The whole point: name a source, get that source, whatever the budget or the ordering would have
    // done. This is what a tie in lastCheckedAt makes impossible today.
    @Test func scopingReadsOnlyTheNamedSource() {
        let all = [source("smoke-ring"), source("carnegie-ish"), source("dessoff")]
        let plan = SourceSchedule.plan(sources: all, depth: .readChanged, only: ["smoke-ring"],
                                       now: Date())
        #expect(plan.fetch.map(\.sourceId) == ["smoke-ring"])
    }

    // The others must not be quietly deferred-and-forgotten either: a scoped run is not a normal run
    // that skipped things, so nothing else should be reported as waiting.
    @Test func theOtherSourcesAreNotTouchedAtAll() {
        let all = [source("a"), source("b"), source("c")]
        let plan = SourceSchedule.plan(sources: all, depth: .readChanged, only: ["b"], now: Date())
        #expect(plan.fetch.map(\.sourceId) == ["b"])
        #expect(plan.deferred.isEmpty)
    }

    // The budget is a backstop against reading fifty sources by accident. Naming ONE source is not an
    // accident, so the cap must not silently drop it (a budget of 0 with an explicit request would
    // read nothing and look like a broken button).
    @Test func anExplicitRequestIsNotSubjectToTheBudget() {
        let all = (1...30).map { source("s\($0)") }
        let plan = SourceSchedule.plan(sources: all, depth: .readChanged, only: ["s30"], budget: 0,
                                       now: Date())
        #expect(plan.fetch.map(\.sourceId) == ["s30"])
    }

    // An org that asked Dan to stop is never checked, and that rule cannot be overridden by naming it.
    // Re-checking an org that asked to be left alone is the one mistake here that cannot be taken back,
    // so the guard has to sit ABOVE the scoping rather than beside it.
    @Test func aStoppedSourceIsNotReadEvenWhenNamed() {
        let s = source("refused")
        s.isActive = false
        s.inactiveReason = .orgRefusal
        let plan = SourceSchedule.plan(sources: [s], depth: .readChanged, only: ["refused"], now: Date())
        #expect(plan.fetch.isEmpty)
    }

    // Scoping to a source that is not on the list reads nothing, rather than falling back to reading
    // everything. A typo must not launch 20 runs.
    @Test func anUnknownIdReadsNothing() {
        let plan = SourceSchedule.plan(sources: [source("a")], depth: .readChanged,
                                       only: ["not-a-source"], now: Date())
        #expect(plan.fetch.isEmpty)
    }

    // Absent scoping is the normal run. This is the regression guard: the ordinary path must not have
    // quietly become a scoped one.
    //
    // #1498: the ordinary run now FETCHES everything rather than the first 20. Fetching is free, and
    // rationing it starved sources that had something to say behind ones that did not; the guard against a
    // surprise spend moved to the paid read, where the money is (ScoutReadBudget). So the assertion is that
    // nothing is skipped, which is the opposite number from before and the whole point of the change.
    @Test func noScopingIsTheOrdinaryRun() {
        let all = (1...25).map { source("s\($0)") }
        let plan = SourceSchedule.plan(sources: all, depth: .readChanged, now: Date())
        #expect(plan.fetch.count == 25)
        #expect(plan.deferred.isEmpty)
    }

    // ...and an explicit ceiling still defers, so that path is live code rather than something only the
    // default used to reach. It is how a caller can still bound a run, and it is what the fairness order
    // exists to make fair.
    @Test func anExplicitCeilingStillDefersTheTail() {
        let all = (1...25).map { source("s\($0)") }
        let plan = SourceSchedule.plan(sources: all, depth: .readChanged, budget: 20, now: Date())
        #expect(plan.fetch.count == 20)
        #expect(plan.deferred.count == 5)
    }

    // The free daily run still watches EVERYTHING. Scoping is about what gets READ, and the watchlist's
    // promise is that a source Dan asked us to watch is always checked. A scoped read must never turn
    // into a scoped watch.
    @Test func scopingNeverNarrowsTheFreeDailyWatch() {
        let all = [source("a"), source("b"), source("c")]
        let plan = SourceSchedule.plan(sources: all, depth: .watchOnly, only: ["b"], now: Date())
        #expect(plan.fetch.count == 3)
    }
}
