import Testing
import Foundation
@testable import Overture

// #1932: what a search runs against, built once when the search starts rather than once per keystroke.
//
// #1926 made the scope something to BUILD rather than something built, so an empty box costs nothing.
// What remained is that every character rebuilt it: a sweep of every prospect plus a map into card
// values, roughly a twentieth of what it replaced, but paid per letter and growing with the store.
//
// The holding rule is a small value with its own tests, because the view that uses it cannot be
// evaluated in a unit test and a rule that lives only inside a SwiftUI body is a rule nothing checks.
@Suite("A search builds its scope once, not once per keystroke (#1932)")
struct SearchScopeTests {
    private func item(_ id: String) -> QueueItem {
        QueueItem(id: id, groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                  performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                  priorRelationship: "none", production: "self", profile: "strong",
                  coverage: "likely_uncovered", fitScore: 4, tier: "mid", fitReason: "r",
                  matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new)
    }

    // A counting stand-in for the sweep, so the test measures what was actually paid for rather than
    // asserting that a cache exists.
    private final class Sweep {
        var count = 0
        var items: [QueueItem]
        init(_ items: [QueueItem]) { self.items = items }
        func build() -> [QueueItem] {
            count += 1
            return items
        }
    }

    // The whole point: ten characters, one sweep.
    @Test func typingAWholeQueryCostsOneSweep() {
        let sweep = Sweep([item("a"), item("b")])
        var scope = SearchScope()

        scope.begin(sweep.build)
        for _ in 0..<10 { _ = scope.items(sweep.build) }

        #expect(sweep.count == 1)
        #expect(scope.items(sweep.build).count == 2)
    }

    // An idle bar builds nothing at all, which is #1926's guarantee and must survive this.
    @Test func aScopeThatWasNeverStartedHoldsNothing() {
        let sweep = Sweep([item("a")])
        let scope = SearchScope()

        #expect(scope.isHolding == false)
        #expect(sweep.count == 0)
    }

    // Emptying the box ends the search, so the next one starts from the store as it is now rather than
    // from a copy taken minutes ago.
    @Test func clearingTheBoxDropsWhatWasHeld() {
        let sweep = Sweep([item("a")])
        var scope = SearchScope()

        scope.begin(sweep.build)
        scope.end()
        #expect(scope.isHolding == false)
        scope.begin(sweep.build)

        #expect(sweep.count == 2)
    }

    // The second search sees shows the first one could not: the held copy is per search, not for the
    // life of the window.
    @Test func aLaterSearchSeesShowsThatArrivedSinceTheEarlierOne() {
        let sweep = Sweep([item("a")])
        var scope = SearchScope()

        scope.begin(sweep.build)
        let duringFirst = scope.items(sweep.build)
        scope.end()
        sweep.items = [item("a"), item("b")]
        scope.begin(sweep.build)
        let duringSecond = scope.items(sweep.build)

        #expect(duringFirst.count == 1)
        #expect(duringSecond.count == 2)
    }

    // Starting a search that is already under way must not sweep again. The view announces the state it
    // is in rather than the transition, so this is asked on every keystroke.
    @Test func startingASearchAlreadyUnderWayChangesNothing() {
        let sweep = Sweep([item("a")])
        var scope = SearchScope()

        scope.begin(sweep.build)
        scope.begin(sweep.build)
        scope.begin(sweep.build)

        #expect(sweep.count == 1)
    }

    // The failure path, and the one that decides whether this is safe: asked for the items before any
    // search was started, it answers from the store rather than with an empty list. A held scope that
    // defaulted to empty would show "no results" for a show that is right there.
    @Test func readingBeforeTheSearchStartedStillAnswersFromTheStore() {
        let sweep = Sweep([item("a"), item("b")])
        let scope = SearchScope()

        let results = scope.items(sweep.build)

        #expect(results.count == 2)
        #expect(sweep.count == 1)
    }
}

// The wiring. The rule above can be perfect while the field still sweeps per keystroke, and no running
// test can evaluate a SwiftUI body, so this guards the shape the way QueueInvalidationGuardTests does.
@Suite("The search field actually holds its scope (#1932)")
struct SearchScopeWiringTests {
    private var field: String { SourceGuardHelper.source("Overture/UI/ShowSearchField.swift") }

    // Both scopes, not just the one the issue named. The archive count sweeps everything Overture has
    // ever tracked and is paid on exactly the queries that find nothing, which is the worst case to
    // leave per keystroke (L30, fix the class).
    @Test func bothScopesAreHeldForTheSearch() {
        #expect(!field.isEmpty)
        #expect(field.contains("@State private var queueScope = SearchScope()"))
        #expect(field.contains("@State private var archiveScope = SearchScope()"))
    }

    // Held or not, the scope is still read through ShowSearch, so the blank-query guard stays where it
    // is and an idle bar builds nothing.
    @Test func theBlankQueryGuardIsStillTheOneInShowSearch() {
        #expect(field.contains("ShowSearch.results(in: queueScope.items(allItems)"))
        #expect(field.contains("ShowSearch.matchCount(in: archiveScope.items(archiveItems)"))
    }

    // And the search's start and end are announced from the field, or nothing ever holds anything.
    @Test func theFieldAnnouncesWhenASearchStartsAndEnds() {
        #expect(field.contains("queueScope.begin(allItems)"))
        #expect(field.contains("queueScope.end()"))
        #expect(field.contains("archiveScope.begin(archiveItems)"))
        #expect(field.contains("archiveScope.end()"))
    }
}
