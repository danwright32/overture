import Testing
import Foundation
@testable import Overture

// #1034: the detached "Reading calendars" phase names the source it is reading RIGHT NOW without any
// new file from the runner. The runner writes results in queue order as it finishes each source, so
// the first queued item not yet present in the results file is the one in flight. This is that diff,
// tested purely against hand-built queue/results fixtures (no run, no files).
@Suite("Scout-extract current source naming (#1034)")
struct ScoutExtractCurrentSourceTests {
    private func queue(_ items: [ScoutExtractQueueItem]) -> ScoutExtractQueue {
        ScoutExtractQueue(version: 2, generatedAt: "2026-07-17T00:00:00Z", items: items)
    }

    private func item(_ id: String, org: String?, listings: String? = nil) -> ScoutExtractQueueItem {
        ScoutExtractQueueItem(sourceId: id, orgName: org, listingsURL: listings, pagePath: "/tmp/\(id).html")
    }

    private func results(_ ids: [String]) -> ScoutExtractResults {
        ScoutExtractResults(version: 1, generatedAt: "2026-07-17T00:00:00Z",
                            results: ids.map { ScoutExtractResult(sourceId: $0, verdict: .upcomingListings, events: []) })
    }

    @Test func namesTheFirstQueuedSourceNotYetInTheResults() {
        let q = queue([item("a", org: "Carnegie Hall"), item("b", org: "Kaufman Music Center"),
                       item("c", org: "Bargemusic")])
        // Source a is done; b is the one being read now.
        #expect(ScoutExtractCurrentSource.currentName(queue: q, results: results(["a"])) == "Kaufman Music Center")
    }

    @Test func namesTheFirstSourceWhenNothingHasBeenReadYet() {
        let q = queue([item("a", org: "Carnegie Hall"), item("b", org: "Kaufman Music Center")])
        #expect(ScoutExtractCurrentSource.currentName(queue: q, results: nil) == "Carnegie Hall")
        #expect(ScoutExtractCurrentSource.currentName(queue: q, results: results([])) == "Carnegie Hall")
    }

    @Test func isNilWhenEverySourceHasBeenReported() {
        // The run is finishing: every queued id is in the results, so there is nothing "in flight".
        let q = queue([item("a", org: "Carnegie Hall"), item("b", org: "Kaufman Music Center")])
        #expect(ScoutExtractCurrentSource.currentName(queue: q, results: results(["a", "b"])) == nil)
    }

    @Test func isNilForAnEmptyQueue() {
        #expect(ScoutExtractCurrentSource.currentName(queue: queue([]), results: nil) == nil)
    }

    // orgName is research-only and can be absent (a pasted lead stores no org). The name must still be
    // something concrete Dan can read, so it falls back to the listing page's host rather than a blank.
    @Test func fallsBackToTheListingHostWhenTheItemHasNoOrgName() {
        let q = queue([item("lead-x", org: nil, listings: "https://www.example.org/events")])
        #expect(ScoutExtractCurrentSource.currentName(queue: q, results: nil) == "www.example.org")
    }

    // A blank/whitespace org name is treated as absent, not shown as an empty line.
    @Test func treatsABlankOrgNameAsAbsent() {
        let q = queue([item("x", org: "   ", listings: "https://host.test/cal")])
        #expect(ScoutExtractCurrentSource.currentName(queue: q, results: nil) == "host.test")
    }

    // Nothing to show at all: no org, no resolvable host. The caller renders no source line rather than
    // a placeholder.
    @Test func isNilWhenThereIsNeitherAnOrgNameNorAResolvableHost() {
        let q = queue([item("x", org: nil, listings: nil)])
        #expect(ScoutExtractCurrentSource.currentName(queue: q, results: nil) == nil)
    }
}
