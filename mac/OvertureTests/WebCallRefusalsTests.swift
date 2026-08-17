import Foundation
import Testing

// #2387: the refusal sentence names WHICH kind of lookup was refused, not just how many.
//
// The run has recorded refusals per route since #1835 and the app decoded none of it, so a browser
// refusal (the tool scope holding exactly as designed, nothing to grant) and a fetch refusal (the run's
// ordinary research blocked) reached Dan as the same sentence. He asked on 2026-08-09 what he was meant
// to do with it, having no way to tell without reading the run's event streams.
@Suite("A refused lookup says which route it was (#2387)")
struct WebCallRefusalsTests {

    // The case that prompted the issue: Dan's own run, whose two refusals were both browser calls the
    // runner is deliberately never given.
    @Test func oneRouteIsNamedWithoutRepeatingTheCount() {
        let clause = WebCallRefusals.routeClause(["browser": 2, "fetch": 0, "search": 0, "bash": 0])
        #expect(clause == " (browser)")
        // The count is already at the front of the sentence ("2 web calls refused"), so repeating it
        // inside the clause would put two figures in one line for one fact (#2616's shape).
        #expect(!clause.contains("2"))
    }

    @Test func severalRoutesEachCarryTheirOwnCount() {
        let clause = WebCallRefusals.routeClause(["fetch": 3, "browser": 1, "search": 0, "bash": 0])
        #expect(clause == " (3 page fetch and 1 browser)")
    }

    @Test func threeRoutesReadAsAList() {
        let clause = WebCallRefusals.routeClause(["fetch": 3, "search": 2, "browser": 1, "bash": 0])
        #expect(clause == " (3 page fetch, 2 web search and 1 browser)")
    }

    // A route that refused NOTHING is not named. Every route is present in the recorded dictionary
    // whether or not it refused anything, so listing them all would name three routes that were fine
    // beside the one that was not.
    @Test func aRouteThatRefusedNothingIsNotNamed() {
        let named = WebCallRefusals.routesWithRefusals(["browser": 1, "fetch": 0, "search": 0, "bash": 0])
        #expect(named.map(\.route) == ["browser"])
    }

    // The order is a property of the data, not of dictionary iteration, which is unordered: without this
    // the same stored run would report a different sentence each time it was read.
    @Test func theOrderIsStableAcrossReads() {
        let recorded = ["fetch": 2, "search": 2, "browser": 5, "bash": 1]
        let readings = (0..<20).map { _ in WebCallRefusals.routeClause(recorded) }
        #expect(Set(readings).count == 1, "the same figures must always produce the same sentence")
        #expect(readings[0] == " (5 browser, 2 page fetch, 2 web search and 1 shell)",
                "most refusals first, alphabetical within a tie")
    }

    // Absent is not zero. A results file written before this was decoded, or by a runner that recorded no
    // routes, says nothing about routes, and the sentence must then read exactly as it did before rather
    // than inventing one (L11).
    @Test func noRecordedRoutesAddsNothingToTheSentence() {
        #expect(WebCallRefusals.routeClause(nil) == "")
        #expect(WebCallRefusals.routeClause([:]) == "")
        #expect(WebCallRefusals.routeClause(["browser": 0, "fetch": 0]) == "")
    }

    // A route the runner grows later is named as itself rather than dropped. Dropping it would report a
    // refusal with no kind at all, which is the state this issue exists to end.
    @Test func anUnrecognisedRouteIsStillNamed() {
        #expect(WebCallRefusals.routeClause(["mcp_lookup": 4]) == " (mcp_lookup)")
    }

    // The four the runner records today, each with words Dan reads rather than the runner's key. Derived
    // from the same list `lib/models.sh` counts, so a rename there shows up here.
    @Test func eachRecordedRouteHasItsOwnWords() {
        let labels = ["fetch", "search", "browser", "bash"].map(WebCallRefusals.label(for:))
        #expect(labels == ["page fetch", "web search", "browser", "shell"])
        #expect(Set(labels).count == labels.count, "two routes reading the same would be unreportable")
    }
}
