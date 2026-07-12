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
