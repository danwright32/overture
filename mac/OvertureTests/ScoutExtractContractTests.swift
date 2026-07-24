import Testing
import Foundation
@testable import Overture

// The scout-extract handoff (#799), guarded by committed fixtures like every other cross-boundary
// file in docs/contracts.md. The app WRITES overture-scout-extract-queue.json (ScoutExtractQueueBuilder)
// and the detached Claude run WRITES overture-scout-extract-results.json, which the app READS
// (ScoutExtractResultsDecoder). The run is a Claude Code workflow, not Swift, so it has no automated
// test of its own: these fixtures plus docs/scout-extract-runbook.md ARE its spec.
//
// Two things here are load-bearing and easy to get wrong:
//
// 1. `sourceId` is OPAQUE. The run echoes it back verbatim and must never rebuild it. This is the
//    same rule PrepQueue learned the hard way ("never reconstruct it; that is what caused the
//    silent-mismatch risk"): a rebuilt key silently matches nothing, and results vanish with no error.
//
// 2. The VERDICT is not decoration. An empty event list means three different things (a quiet
//    off-season, the wrong page, a page we cannot read at all), and only the verdict tells them
//    apart. A results file whose verdict does not decode is a source whose health we cannot judge.
@Suite("Scout extract contract fixtures (#799)")
struct ScoutExtractContractTests {
    private func fixtureDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/scout-extract")
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureDirectory().appendingPathComponent(name))
    }

    private func fixtureFileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory().path)
            .filter { $0.hasSuffix(".json") }
    }

    // Enumerates whatever is actually committed (#491/#744), so a new fixture with no matching decode
    // case fails HERE rather than silently shipping with zero coverage on this side.
    @Test func decodesEveryCommittedFixtureWithoutThrowing() throws {
        let names = try fixtureFileNames()
        #expect(!names.isEmpty)
        for name in names {
            let data = try fixture(name)
            if name.hasPrefix("queue") {
                #expect(throws: Never.self) { try JSONDecoder().decode(ScoutExtractQueue.self, from: data) }
            } else if name.hasPrefix("results") {
                #expect(throws: Never.self) { try ScoutExtractResultsDecoder.decode(data) }
            } else if name.hasPrefix("progress") {
                #expect(throws: Never.self) { try ScoutExtractProgressDecoder.decode(data) }
            } else {
                Issue.record("Fixture \(name) matches no decode case; the contract test would not cover it.")
            }
        }
    }

    // v2: the queue can name the ONE org whose shows count on this page. It exists because a VENUE page
    // is a page about many organizations: Lincoln Center's page for one ensemble's concert also carries
    // an "Alice Tully Hall upcoming events" sidebar, and without this the run returned the hall's other
    // tenants (real shows, right hall, WRONG ORG) as if they were the lead.
    @Test func theQueueCanConstrainAPageToOneOrgsShows() throws {
        let queue = try JSONDecoder().decode(ScoutExtractQueue.self, from: fixture("queue-v2.json"))
        #expect(queue.version == 2)
        #expect(queue.items.first?.onlyForOrg == "Second Ending Ensemble")
    }

    // Additive, so the older shape still decodes: an absent constraint means "every show on this page
    // counts", which is exactly right when Dan pasted a venue's own calendar on purpose.
    @Test func aQueueWithNoConstraintStillDecodesAndMeansNoConstraint() throws {
        let queue = try JSONDecoder().decode(ScoutExtractQueue.self, from: fixture("queue-v1.json"))
        #expect(queue.items.allSatisfy { $0.onlyForOrg == nil })
    }

    @Test func theQueuePointsTheRunAtAPinnedPageAndAnOpaqueSourceId() throws {
        let queue = try JSONDecoder().decode(ScoutExtractQueue.self, from: fixture("queue-v1.json"))

        #expect(queue.version == 1)
        #expect(queue.items.count == 2)
        let barge = try #require(queue.items.first { $0.sourceId == "bargemusic" })
        #expect(barge.pagePath.hasSuffix(".html"))          // the run READS this file; it does not fetch
        #expect(barge.listingsURL == "https://www.bargemusic.org/calendar-tickets/")
        #expect(barge.orgName == "Bargemusic")
    }

    // The two real shapes the #770 spike found, both of which the app must handle without confusing
    // one for the other. Chelsea's page is FULL of concerts and every one of them is past; Bargemusic
    // genuinely has upcoming shows. Same file, opposite meanings.
    // #970 Phase 1. The run reports WHERE a show is, verbatim, as the page wrote it.
    //
    // This exists because the alternatives were measured and do not work. Reading the city out of the
    // venue string is unreliable: a venue only picks up a comma when a source page bakes a full street
    // address into it (#1030), an artifact of the address rather than a location report. Reading it out
    // of the title fires only on Carnegie's NYO tour convention, and on no other source. The touring
    // artist pages this is for carry the city in a field of their own, and often name no venue at all,
    // so the only way the app can learn a place is for the run to hand it over.
    //
    // Verbatim, NOT normalized: the run must not decide what "Harrogate, UK" means. Every real shape
    // has to survive the wire intact for the resolver to judge later.
    @Test func resultsCarryTheLocationThePageShowed() throws {
        let results = try ScoutExtractResultsDecoder.decode(fixture("results-v2.json"))
        let smoke = try #require(results.results.first { $0.sourceId == "smoke-ring-quartet" })

        let gotham = try #require(smoke.events.first { $0.title == "Gotham Chorus Show" })
        #expect(gotham.location == "New York, NY")

        let labbs = try #require(smoke.events.first { $0.title == "LABBS 50th Convention" })
        #expect(labbs.location == "Harrogate, UK")
    }

    // A page that names no location is normal, not broken: "Carnegie Hall Debut Recital" is a real row
    // from a real artist site that publishes a venue and no city. It must decode as absent, so the
    // resolver can keep and flag it rather than mistake silence for a place.
    @Test func anEventWithNoLocationDecodesAsAbsent() throws {
        let results = try ScoutExtractResultsDecoder.decode(fixture("results-v2.json"))
        let smoke = try #require(results.results.first { $0.sourceId == "smoke-ring-quartet" })
        let debut = try #require(smoke.events.first { $0.title == "Carnegie Hall Debut Recital" })
        #expect(debut.location == nil)
    }

    // The field is optional, so a v1 file written before the run was ever asked for a location still
    // decodes. It resolves to no location at all, which is the same answer as a v2 run that looked and
    // found none: both are unknown, both are kept and flagged. The app cannot tell them apart and does
    // not need to, so do not add a version check to invent the distinction.
    @Test func aVersionOneResultsFileStillDecodesWithNoLocations() throws {
        let results = try ScoutExtractResultsDecoder.decode(fixture("results-v1.json"))
        let barge = try #require(results.results.first { $0.sourceId == "bargemusic" })
        #expect(barge.events.count == 2)
        #expect(barge.events.allSatisfy { $0.location == nil })
    }

    // v3 (#897): a stitched multi-month result reports which months the run actually read, so the app can
    // tell a full sweep from a page it only skimmed part of. Verbatim off the wire; the completeness rule
    // lives in SweepCoverage, not in the decoder.
    @Test func aVersionThreeResultsFileCarriesTheMonthsTheRunRead() throws {
        let results = try ScoutExtractResultsDecoder.decode(fixture("results-v3.json"))
        let kaufman = try #require(results.results.first { $0.sourceId == "kaufman-music-center" })
        #expect(kaufman.monthsCovered == ["2026-07", "2026-08", "2026-09", "2026-10"])
    }

    // The field is optional, so a v1/v2 file written before the run was ever asked which months it read
    // still decodes and simply carries none. A single-month page never needs it, which is why the check
    // it feeds (SweepCoverage) is inert whenever it is absent.
    @Test func anEarlierResultsFileDecodesWithNoMonthsCovered() throws {
        let v2 = try ScoutExtractResultsDecoder.decode(fixture("results-v2.json"))
        #expect(v2.results.allSatisfy { $0.monthsCovered == nil })
        let v1 = try ScoutExtractResultsDecoder.decode(fixture("results-v1.json"))
        #expect(v1.results.allSatisfy { $0.monthsCovered == nil })
    }

    // v4 (#1174): every night of one production carries the source's shared seriesId, so RunGrouping can
    // collapse a multi-night run (VenueTix's Green Room 42) into one prospect regardless of the gap. The
    // wire carries the id verbatim; the grouping rule lives in RunGrouping, not the decoder.
    @Test func aVersionFourResultsFileCarriesTheSharedSeriesId() throws {
        let results = try ScoutExtractResultsDecoder.decode(fixture("results-v4.json"))
        let gr42 = try #require(results.results.first { $0.sourceId == "the-green-room-42" })

        let run = gr42.events.filter { $0.seriesId == "run-1" }
        #expect(run.count == 3)                                   // the three nights of the run share it
        let standalone = try #require(gr42.events.first { $0.title == "A One Night Only Cabaret" })
        #expect(standalone.seriesId == nil)                       // the one-off carries none
    }

    // The field is optional, so a v1/v2/v3 file written before the run was ever asked for a seriesId still
    // decodes and simply carries none. That is the same outcome as a v4 run reading a source that publishes
    // no production id, which is nearly all of them.
    @Test func anEarlierResultsFileDecodesWithNoSeriesId() throws {
        for name in ["results-v1.json", "results-v2.json", "results-v3.json"] {
            let results = try ScoutExtractResultsDecoder.decode(fixture(name))
            #expect(results.results.allSatisfy { $0.events.allSatisfy { $0.seriesId == nil } })
        }
    }

    // v5 (#1469): a row whose venue the PAGE ITSELF has not published yet says so, so the app can tell it
    // apart from a row whose detail page the run could not open. Smoke Ring's real Oct 24 Palm Springs gig
    // is the case: the band's own page prints "Info coming soon" with no title, no venue and no link.
    @Test func aVersionFiveResultsFileMarksARowThePageHasNotPublishedAVenueFor() throws {
        let results = try ScoutExtractResultsDecoder.decode(fixture("results-v5.json"))
        let smokeRing = try #require(results.results.first { $0.sourceId == "smoke-ring-quartet" })

        let placeholder = try #require(smokeRing.events.first { $0.performanceDate == "2026-10-24" })
        #expect(placeholder.venueNotPublished == true)
        #expect(placeholder.venue == nil)
        #expect(placeholder.sourceUrl == nil)           // the placeholder row links nowhere, as on the real page
        // Every row the run DID read a venue off carries no flag, so the two cases stay distinguishable.
        #expect(smokeRing.events.filter { $0.venueNotPublished == true }.count == 1)
    }

    // The field is optional, so a file written before the run was ever asked for it still decodes and simply
    // carries none. That is the same outcome as a v5 run whose pages all published their venues, which is
    // nearly every run, so the app cannot tell those apart and does not need to.
    @Test func anEarlierResultsFileDecodesWithNoVenueNotPublishedFlag() throws {
        for name in ["results-v1.json", "results-v2.json", "results-v3.json", "results-v4.json"] {
            let results = try ScoutExtractResultsDecoder.decode(fixture(name))
            #expect(results.results.allSatisfy { $0.events.allSatisfy { $0.venueNotPublished == nil } })
        }
    }

    // Decoding is not enough: the flag has to survive the hop into the app's own event type, or the
    // readability rule downstream would go on counting the placeholder as an unread page while this suite
    // stayed green. Read through `rawEvents` the way the ingest sees it, not off the wire struct.
    @Test func theVenueNotPublishedFlagSurvivesTheHopIntoTheAppsOwnEventType() throws {
        let results = try ScoutExtractResultsDecoder.decode(fixture("results-v5.json"))

        let tally = results.rejectionCounts(for: "smoke-ring-quartet")

        #expect(tally.structuralGapCount == 1)
        #expect(tally.unreadTotal == 0)
        #expect(tally.structuralGapDates == ["2026-10-24"])
    }

    // The seriesId decodes off the wire AND survives the hop into the app's own ExtractedEvent, the same
    // way `location` must: a field that decoded but fell out of `asExtractedEvent` would leave this green
    // while RunGrouping downstream still saw nothing to collapse.
    @Test func theSeriesIdSurvivesTheHopIntoTheAppsOwnEventType() throws {
        let results = try ScoutExtractResultsDecoder.decode(fixture("results-v4.json"))
        let events = results.events(for: "the-green-room-42")
        let run = events.filter { $0.seriesId == "run-1" }
        #expect(run.count == 3)
    }

    // ScoutExtractEvent mirrors ExtractedEvent field for field and converts straight across, on purpose:
    // #799's whole point is ONE pipeline, so an agent-read event and a Carnegie-read event are the same
    // thing downstream. A location that decodes off the wire and then falls out of `asExtractedEvent`
    // would leave the contract test green while the app still knew nothing about where a show is.
    @Test func theLocationSurvivesTheHopIntoTheAppsOwnEventType() throws {
        let results = try ScoutExtractResultsDecoder.decode(fixture("results-v2.json"))
        let smoke = try #require(results.results.first { $0.sourceId == "smoke-ring-quartet" })
        let labbs = try #require(smoke.events.first { $0.title == "LABBS 50th Convention" })
        #expect(labbs.asExtractedEvent.location == "Harrogate, UK")
    }

    @Test func resultsCarryAVerdictThatDistinguishesQuietFromBroken() throws {
        let results = try ScoutExtractResultsDecoder.decode(fixture("results-v1.json"))

        let chelsea = try #require(results.results.first { $0.sourceId == "chelsea-symphony" })
        #expect(chelsea.verdict == .allPast)
        #expect(chelsea.events.isEmpty)
        #expect(chelsea.note?.isEmpty == false)             // the run says WHY, so Dan is not guessing

        let barge = try #require(results.results.first { $0.sourceId == "bargemusic" })
        #expect(barge.verdict == .upcomingListings)
        #expect(barge.events.count == 2)
        #expect(barge.events.first?.venue == "Bargemusic")  // spike finding 4: the venue must come back
    }

    // The results decode straight into the SAME ExtractedEvent the rest of the pipeline already
    // consumes, which is what keeps this one pipeline and not two. If this ever needs a translation
    // layer, the contract has drifted.
    @Test func aResultsEventIsTheSameShapeTheScoutPipelineAlreadyEats() throws {
        let results = try ScoutExtractResultsDecoder.decode(fixture("results-v1.json"))
        let events: [ExtractedEvent] = results.events(for: "bargemusic")

        #expect(events.count == 2)
        #expect(events.first?.title == "Complete Beethoven Piano Sonatas with Conversation Part 2")
        #expect(events.first?.performanceDate == "2026-07-25")
    }

    // An unknown source id in the results is a run that echoed a key it invented, which is the exact
    // silent-mismatch PrepQueue's "opaque, echo verbatim" rule exists to prevent. It must read as
    // "no events for that source", never as a crash and never as somebody else's events.
    @Test func anUnknownSourceIdYieldsNothingRatherThanTheWrongSourcesEvents() throws {
        let results = try ScoutExtractResultsDecoder.decode(fixture("results-v1.json"))
        #expect(results.events(for: "a-source-that-was-never-queued").isEmpty)
        #expect(results.verdict(for: "a-source-that-was-never-queued") == nil)
    }

    @Test func progressIsTheSameNOfMShapeTheToolbarAlreadyKnows() throws {
        let progress = try ScoutExtractProgressDecoder.decode(fixture("progress-v1.json"))
        #expect(progress.total == 2)
        #expect(progress.completed == 1)
        #expect(ScoutExtractProgressDecoder.label(from: progress) == "1 of 2")
    }

    // The failure paths of the progress READ, which are not edge cases here but the normal condition:
    // the toolbar polls this file while a detached run is actively writing it, so it will routinely
    // catch it missing (the run has not seeded it yet) or half-written (caught mid-flush).
    //
    // All of those must read as "nothing to show yet" and leave the live label alone. They must NEVER
    // throw, and they must never be mistaken for a run that has finished or failed: the label falling
    // back to nothing is the difference between a spinner that keeps counting and a UI that looks dead
    // while the run is in fact fine.
    @Test func aMissingOrHalfWrittenProgressFileReadsAsNothingToShowNotAnError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scout-extract-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Missing: the script has not seeded it yet.
        let missing = dir.appendingPathComponent("absent.json")
        #expect(ScoutExtractProgressDecoder.loadCurrent(from: missing) == nil)

        // Half-written: caught mid-flush, so the JSON is truncated.
        let partial = dir.appendingPathComponent("partial.json")
        try Data(#"{"version":1,"total":9,"comp"#.utf8).write(to: partial)
        #expect(ScoutExtractProgressDecoder.loadCurrent(from: partial) == nil)

        // Present and whole: the only case that yields a label.
        let whole = dir.appendingPathComponent("whole.json")
        try Data(#"{"version":1,"total":9,"completed":3}"#.utf8).write(to: whole)
        let progress = try #require(ScoutExtractProgressDecoder.loadCurrent(from: whole))
        #expect(ScoutExtractProgressDecoder.label(from: progress) == "3 of 9")
    }

    // A run that overshoots (it wrote completed 10 of 9, or the queue shrank under it) must not print
    // "10 of 9", which reads as a bug in Overture rather than in the run. And a zero-total file has
    // nothing to say, so it says nothing rather than "0 of 0".
    @Test func anImpossibleProgressCountIsShownSanelyOrNotAtAll() {
        #expect(ScoutExtractProgressDecoder.label(
            from: ScoutExtractProgress(version: 1, total: 9, completed: 12)) == "9 of 9")
        #expect(ScoutExtractProgressDecoder.label(
            from: ScoutExtractProgress(version: 1, total: 0, completed: 0)) == nil)
        #expect(ScoutExtractProgressDecoder.label(from: nil) == nil)
    }

    // The app WRITES the queue, so its encoding is the half we can actually pin. Round-tripping it
    // through the decoder proves the run will be handed exactly what the fixture promises.
    @Test func theQueueTheAppWritesRoundTrips() throws {
        let queue = ScoutExtractQueueBuilder.build(
            items: [ScoutExtractQueueItem(sourceId: "bargemusic", orgName: "Bargemusic",
                                          listingsURL: "https://www.bargemusic.org/calendar-tickets/",
                                          pagePath: "/tmp/overture-scout-page-bargemusic.html")],
            generatedAt: "2026-07-11T18:04:00Z")

        let data = try ScoutExtractQueueBuilder.encode(queue)
        let decoded = try JSONDecoder().decode(ScoutExtractQueue.self, from: data)

        #expect(decoded == queue)
        #expect(decoded.version == ScoutExtractQueueBuilder.version)
    }
}
