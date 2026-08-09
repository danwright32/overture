import Testing
import Foundation

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

// #2216: which sources a run in flight is still going to read.
//
// Dan pressed scout, looked at the Sources sheet nine minutes later, and saw two rows telling him to run
// a scout. He had just run one, and it was reading those exact two pages: four detached runs alive, 18 of
// 30 pages done, both sources queued in chunks still working. Every stored fact on those rows was
// correct; one sentence was covering two situations, and told the wrong one he pressed scout again.
@Suite("Which sources a live run is still to read (#2216)")
struct ScoutReadInFlightTests {
    private func queue(_ ids: [String]) -> ScoutExtractQueue {
        ScoutExtractQueue(version: 2, generatedAt: "2026-08-06T21:21:00Z",
                          items: ids.map { ScoutExtractQueueItem(sourceId: $0, orgName: $0,
                                                                 listingsURL: nil, pagePath: "/tmp/\($0).html") })
    }

    private func results(_ ids: [String]) -> ScoutExtractResults {
        ScoutExtractResults(version: 1, generatedAt: "2026-08-06T21:29:00Z",
                            results: ids.map { ScoutExtractResult(sourceId: $0, verdict: .upcomingListings, events: []) })
    }

    // The night this was found: masterwork-org was next up in chunk 2, tenet-nyc last in chunk 3, and
    // both were still to be read.
    @Test func aQueuedSourceNotYetReportedIsStillToBeRead() {
        let ids = ScoutReadInFlight.sourceIdsStillToRead(
            isRunning: true,
            queue: queue(["masterwork-org", "tenet-nyc", "roulette"]),
            results: results(["roulette"]))

        #expect(ids == ["masterwork-org", "tenet-nyc"])
    }

    // The failure path, and the one that keeps the request honest: with no run in flight, a queue file
    // left over from the last run must speak for nothing. Otherwise every source in the last run's queue
    // would claim to be being read, and the row would stop asking for the scout it genuinely needs.
    @Test func aStaleQueueWithNoRunInFlightSpeaksForNothing() {
        let ids = ScoutReadInFlight.sourceIdsStillToRead(
            isRunning: false,
            queue: queue(["masterwork-org", "tenet-nyc"]),
            results: nil)

        #expect(ids.isEmpty)
    }

    // A run whose results file has not appeared yet has read nothing, so everything it was asked for is
    // still to come.
    @Test func aRunThatHasReportedNothingYetOwesTheWholeQueue() {
        let ids = ScoutReadInFlight.sourceIdsStillToRead(
            isRunning: true, queue: queue(["a", "b"]), results: nil)

        #expect(ids == ["a", "b"])
    }

    // A source this run was never asked about is not being read by it, however busy the run is. That is
    // the third case the issue names: the run will not reach it, so the row must still ask for a scout.
    @Test func aSourceOutsideTheQueueIsNotBeingRead() {
        let ids = ScoutReadInFlight.sourceIdsStillToRead(
            isRunning: true, queue: queue(["a", "b"]), results: results(["a"]))

        #expect(!ids.contains("somebody-else"))
    }

    @Test func aRunThatHasReportedEverythingOwesNothing() {
        let ids = ScoutReadInFlight.sourceIdsStillToRead(
            isRunning: true, queue: queue(["a", "b"]), results: results(["a", "b"]))

        #expect(ids.isEmpty)
    }
}

// The sentence the row shows, which is where the two situations were collapsed into one.
@Suite("What a row with unread listings says while a run is reading it (#2216)")
struct UnreadListingsLineTests {
    private let state = SourceReadState.unreadChangesWaiting(lastRead: nil)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aSourceTheRunIsReadingDoesNotAskForAScout() {
        let line = state.label(now: now, beingReadNow: true)

        #expect(!line.contains("Run a scout"), "it asks for the scout that is already reading this page")
        #expect(line == "New listings. The scout is reading them now.")
    }

    // The failure path: with no run reading it, the row still asks, because nothing else will read it.
    @Test func aSourceNoRunIsReadingStillAsksForAScout() {
        let line = state.label(now: now, beingReadNow: false)

        #expect(line == "New listings, not read yet. Run a scout to read them.")
    }

    // Gold is for what Dan must act on. A row being handled is not one of those.
    @Test func aSourceTheRunIsReadingIsNotDrawnAsSomethingToActOn() {
        #expect(!state.needsAScout(beingReadNow: true))
        #expect(state.needsAScout(beingReadNow: false))
    }

    // Only this state changes. A read or never-read row says the same thing either way, so a run in
    // flight cannot rewrite a line that was never about it.
    @Test func noOtherStateChangesWhileARunIsInFlight() {
        for other in [SourceReadState.neverRead, .read(at: now)] {
            #expect(other.label(now: now, beingReadNow: true) == other.label(now: now, beingReadNow: false))
            #expect(!other.needsAScout(beingReadNow: true))
        }
    }
}

