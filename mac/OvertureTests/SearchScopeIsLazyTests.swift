import Testing
import Foundation
@testable import Overture

private func item(id: String = "k", groupName: String = "Aurora Strings",
                  venue: String? = "Weill Recital Hall",
                  performanceDate: String? = "2026-07-01") -> QueueItem {
    QueueItem(
        id: id, groupName: groupName, discipline: "music", venue: venue,
        performanceDate: performanceDate, sourceListingURL: nil, websiteURL: nil,
        priorRelationship: "none", production: "self", profile: "neutral",
        coverage: "unknown", fitScore: 5, tier: "mid", fitReason: "reason",
        matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new
    )
}

// #1926: what an empty search box is allowed to cost.
//
// The shows the queue's bar can search are not sitting in a variable: working them out is a
// StageNavigation.stagedKeys sweep of every prospect plus a map over all of them, and it was written as
// an ARGUMENT at the call site, so it ran on every render pass whether or not Dan was searching. An
// argument evaluates before the function it is handed to can decide it is not needed, which is #1916's
// lesson and the reason this list arrives as a closure the matcher may decline to call.
//
// Counted rather than timed: how many times the list is built is exactly the thing under test, and a
// count cannot go flaky.
@Suite("Searching builds the show list only when there is something to search for (#1926)")
struct SearchScopeIsLazyTests {
    @Test func aBlankQueryNeverBuildsTheShowList() {
        var builds = 0
        let shows: () -> [QueueItem] = { builds += 1; return [item()] }

        #expect(ShowSearch.results(in: shows(), query: "").isEmpty)
        #expect(builds == 0)

        #expect(ShowSearch.results(in: shows(), query: "   ").isEmpty)
        #expect(builds == 0)
    }

    @Test func aRealQueryBuildsTheListOnce() {
        var builds = 0
        let shows: () -> [QueueItem] = { builds += 1; return [item(groupName: "Aurora Strings")] }

        let found = ShowSearch.results(in: shows(), query: "aurora")

        #expect(found.map(\.groupName) == ["Aurora Strings"])
        #expect(builds == 1)
    }

    // The ordering and the cap came out of the view with the matching, so they are asserted here rather
    // than being three lines of a SwiftUI body no test can reach.
    @Test func resultsAreNewestFirstAndCapped() {
        let shows = (1...12).map { n in
            item(id: "k\(n)", groupName: "Aurora \(n)", performanceDate: String(format: "2026-07-%02d", n))
        }

        let found = ShowSearch.results(in: shows, query: "aurora")

        #expect(found.count == 8)
        #expect(found.first?.performanceDate == "2026-07-12")
        #expect(found.last?.performanceDate == "2026-07-05")
    }

    // A show with no date still has to be findable. Sorting it against a dated one is arbitrary; losing
    // it is not, and a nil-unsafe sort is the ordinary way that happens.
    @Test func anUndatedShowIsStillFound() {
        let found = ShowSearch.results(in: [item(groupName: "Aurora Strings", performanceDate: nil)],
                                       query: "aurora")
        #expect(found.count == 1)
    }

    // #1580's Archive count is the same shape: it exists to say the show is somewhere else, so on a blank
    // query there is nothing to say and nothing to build.
    @Test func theArchiveCountIsLazyToo() {
        var builds = 0
        let shows: () -> [QueueItem] = { builds += 1; return [item(groupName: "Aurora Strings")] }

        #expect(ShowSearch.matchCount(in: shows(), query: "") == 0)
        #expect(builds == 0)

        #expect(ShowSearch.matchCount(in: shows(), query: "aurora") == 1)
        #expect(builds == 1)
    }

    // The counterpart to the blank-query cases: a query that matches nothing must still have LOOKED,
    // because "found nothing" and "never searched" are the same empty list on screen and the empty state
    // says different things about them.
    @Test func aQueryThatMatchesNothingStillSearched() {
        var builds = 0
        let shows: () -> [QueueItem] = { builds += 1; return [item(groupName: "Aurora Strings")] }

        #expect(ShowSearch.results(in: shows(), query: "lumen").isEmpty)
        #expect(builds == 1)
    }
}
