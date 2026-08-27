import Testing
import Foundation
import SwiftData

// #1813: `reachability-probe-run.json` is a fixed-shape JSON handoff file like every other one in
// `docs/contracts.md`, and until now it was in neither that catalog nor `fixtures/`. Both of its sides are
// the app (`PrepQueueService.startReachabilityProbe` writes it, the completion path reads it), so there is
// no second language to disagree with, but there IS a second point in TIME: a marker written by one build
// is read by whatever build is installed when the run comes home, and #1809 changed its shape mid-flight.
//
// What the fixtures pin is that older shape. `settleAttempts` is optional precisely because Swift's
// synthesized decoding does not apply a property's default value, so a non-optional there would have failed
// to decode every marker written before the field existed, which is exactly the paid run the field was
// added to protect.
@Suite("Reachability probe marker contract fixtures (#1813)")
struct ReachabilityProbeMarkerContractTests {

    private func fixtureDirectory() -> URL {
        RepoRoot.url.appendingPathComponent("fixtures/reachability-probe-run")
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureDirectory().appendingPathComponent(name))
    }

    private func fixtureFileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory().path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("reachability-probe-run.json")
    }

    // The reader as the app really calls it, rather than a bare JSONDecoder: `read` is what every caller
    // in the app goes through, so a fixture that decodes only through a decoder written here would prove
    // nothing about the file the app actually opens.
    private func readingFixture(_ name: String) throws -> ReachabilityProbeMarker? {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try fixture(name).write(to: url)
        return try ReachabilityProbeMarker.read(from: url)
    }

    // #491/#744's rule, applied here: enumerate whatever is committed, so a new fixture file with no
    // matching case fails here rather than shipping with zero coverage on this side.
    @Test func everyCommittedFixtureIsReadableByTheApp() throws {
        let names = try fixtureFileNames()
        #expect(names.count >= 2)
        for name in names {
            #expect(try readingFixture(name) != nil, "\(name) did not read back")
        }
    }

    // THE BACKWARD-COMPATIBILITY PIN, and the reason this contract is worth registering at all.
    //
    // `launched.json` is the shape the writer emits at launch, which is also byte-for-byte the shape every
    // marker had before #1809: the field is simply not in the file. A build that made `settleAttempts`
    // non-optional would fail to read this, and a check that finished while Dan's app was closed would come
    // home to a marker its own reader could not open.
    @Test func aMarkerWrittenBeforeSettleAttemptsExistedStillReads() throws {
        let json = try String(data: try fixture("launched.json"), encoding: .utf8)!
        #expect(!json.contains("settleAttempts"), "the pre-#1809 fixture must not carry the field at all")

        let marker = try #require(try readingFixture("launched.json"))
        #expect(marker.settleAttempts == nil)
        #expect(marker.startedAt == "2026-08-07T14:04:21Z")
        #expect(marker.keys == Set([
            "summer lovin|2026-08-11|the green room 42",
            "cabaret for the chronically dramatic|2026-08-11|54 below",
            "devin marlowe|2026-08-11|54 below",
        ]))
    }

    // The current shape, which the settle rewrites after a stamp save that would not commit.
    @Test func theRetriedFixtureCarriesItsAttemptCount() throws {
        let marker = try #require(try readingFixture("settle-retried.json"))
        #expect(marker.settleAttempts == 2)
        #expect(marker.keys.count == 3)
        // The count in that fixture is one short of giving up, which is what makes it the interesting
        // one to keep: the next failed settle releases the marker and reports that it stopped trying.
        #expect(marker.settleAttempts == ReachabilityProbeMarker.maxSettleAttempts - 1)
    }

    // Both fixtures were PRODUCED BY THE WRITER, not typed out (L48, and the convention
    // `fixtures/update-result/` already follows). This is what keeps that true: what the app writes today
    // must still be what is committed here, or the fixture has quietly become a record of an older shape.
    //
    // Compared as parsed JSON with the key list sorted rather than byte for byte, because `keys` is a Set
    // and Swift's Set iteration order is not stable between processes. A byte comparison here would fail
    // at random.
    @Test func theCommittedFixturesAreWhatTheWriterEmitsToday() throws {
        for (name, marker) in [
            ("launched.json", ReachabilityProbeMarker(keys: try #require(try readingFixture("launched.json")).keys,
                                                      startedAt: "2026-08-07T14:04:21Z")),
            ("settle-retried.json", ReachabilityProbeMarker(
                keys: try #require(try readingFixture("settle-retried.json")).keys,
                startedAt: "2026-08-07T14:04:21Z",
                settleAttempts: 2)),
        ] {
            let url = tempURL()
            try ReachabilityProbeMarker.write(marker, to: url)
            #expect(try normalized(Data(contentsOf: url)) == normalized(try fixture(name)),
                    "\(name) is no longer what the writer emits")
        }
    }

    private func normalized(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let keys = (object["keys"] as? [String] ?? []).sorted()
        var copy = object
        copy["keys"] = keys
        return String(data: try JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys]),
                      encoding: .utf8) ?? ""
    }

    // MARK: - Negative paths
    //
    // A guard that cannot fail is not a guard. These prove a drifted marker would actually be caught,
    // rather than half-read into a record that names the wrong shows.

    private func writing(_ json: String) throws -> URL {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test func aMarkerMissingAKeyFieldIsRejectedRatherThanHalfRead() throws {
        #expect(throws: (any Error).self) {
            try ReachabilityProbeMarker.read(from: try writing(#"{"startedAt":"2026-08-07T14:04:21Z"}"#))
        }
        #expect(throws: (any Error).self) {
            try ReachabilityProbeMarker.read(from: try writing(#"{"keys":["a|b|c"]}"#))
        }
    }

    @Test func garbageIsRejectedRatherThanReadAsAnEmptyCheck() throws {
        #expect(throws: (any Error).self) {
            try ReachabilityProbeMarker.read(from: try writing("not json at all"))
        }
    }

    // A file that is not there is not an error: no check was launched, which is the ordinary case.
    @Test func anAbsentMarkerIsNotAnError() throws {
        #expect(try ReachabilityProbeMarker.read(from: tempURL()) == nil)
    }
}

// THE FAILURE PATH, which is the half of this issue that is about behavior rather than shape.
//
// A marker that cannot be decoded at all must leave the completion path treating the finished run as a
// PREP run. That direction is safe; the other one is what #1809 cost: a run read as a check ingests
// probe-safely, short-circuits before any draft handling, and every draft it wrote is discarded with
// nothing on screen saying why.
//
// Asserted through `settleReachabilityProbe`, which is the shipping decision (RootView calls it with its
// default URLs and ingests as a Prep run whenever it returns nil), not through a helper written for the
// test. The wire from that nil to `ingestPrep()` is the separate claim held by the last test here.
@MainActor
@Suite("An unreadable check marker leaves the run a Prep run (#1813)")
struct UnreadableCheckMarkerTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func newProspect(_ ctx: ModelContext, group: String) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-09-12",
                                          venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2026-09-12", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    private func dir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "probe-marker-contract-\(UUID().uuidString)")!
    }

    private func writeResults(_ url: URL, _ results: PrepResults) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(results).write(to: url)
    }

    // A results file carrying a real draft, which is what a Prep run produces and a check never does.
    private func resultsWithADraft(for key: String) -> PrepResults {
        PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: key,
                       contacts: [PrepContact(name: "Jane", role: "Mgr", email: "jane@aurora.org",
                                              method: "named_decision_maker", confidence: "high",
                                              formUrl: nil, provenance: "act")],
                       draft: PrepDraft(subject: "Photographing your September concert",
                                        body: "I photograph performing arts in New York.", variant: "A"))
        ])
    }

    @Test func anUndecodableMarkerIsNotACheckAndKeepsTheDraft() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        let markerURL = d.appendingPathComponent("reachability-probe-run.json")
        let resultsURL = d.appendingPathComponent("overture-prep-results.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let defaults = freshDefaults()
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        // A marker truncated mid-write, which is the realistic corruption: the file exists, so a rule
        // resting on its PRESENCE would call this a check.
        try Data(#"{"keys":["aurora-strings|2026-"#.utf8).write(to: markerURL)
        try writeResults(resultsURL, resultsWithADraft(for: key))

        let report = PrepQueueService.settleReachabilityProbe(slot: .check, 
            markerURL: markerURL, resultsURL: resultsURL, into: ctx, now: now, defaults: defaults)

        // Not a check: the settle declines, which is what sends RootView down the Prep ingest.
        #expect(report == nil)
        let after = try ctx.fetch(FetchDescriptor<Prospect>()).first
        #expect(after?.reachabilityProbedAt == nil, "an unreadable marker must not stamp any show probed")
        // And, the point of the whole issue: the results file is untouched, so the Prep ingest that
        // follows still has the run's work to read.
        #expect(PrepImporter.hasUnconsumedResults(slot: .prep, at: resultsURL, defaults: defaults))

        // The rest of the shipping completion path, exactly as `ingestPrep()` performs it.
        let outcome = PrepImporter.consumeIfNew(slot: .prep, 
            at: resultsURL, into: ctx, defaults: defaults,
            ingest: { try PrepImporter.ingestFile(at: $0, into: $1, isProbe: false, now: now) })
        #expect(outcome?.drafted == 1, "the draft the run wrote must land, not be discarded")
        let drafted = try ctx.fetch(FetchDescriptor<Prospect>()).first
        #expect(drafted?.draftSubject == "Photographing your September concert")
    }

    // And the feature still works: a marker that IS readable is still a check, so the safe default above
    // has not been bought by turning the check off.
    @Test func aReadableMarkerIsStillACheck() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx, group: "Aurora Strings")
        let d = dir()
        let markerURL = d.appendingPathComponent("reachability-probe-run.json")
        let resultsURL = d.appendingPathComponent("overture-prep-results.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [key], startedAt: "s"), to: markerURL)
        try writeResults(resultsURL, resultsWithADraft(for: key))

        let report = PrepQueueService.settleReachabilityProbe(slot: .check, 
            markerURL: markerURL, resultsURL: resultsURL, into: ctx, now: now, defaults: freshDefaults())

        #expect(report != nil)
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).first?.reachabilityProbedAt == now)
    }

    // THE WIRE, a separate claim from the rule above (a guard and its wiring are two things).
    //
    // Every test here calls `settleReachabilityProbe` directly, so all of them stay green if the view
    // stops routing on its answer. `settleFinishedPrepRun` lives inside a SwiftUI view where no test can
    // reach it (#885), so this is held by a source guard, the project's existing convention for this shape.
    @Test func theCompletionPathIngestsAsAPrepRunWhenTheSettleDeclines() throws {
        let rootView = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(!rootView.isEmpty)

        let body = try SourceGuard.functionBody(named: "settleFinishedRun", in: rootView)
        // The nil answer is what falls through to the Prep ingest. Both halves are asserted: the routing
        // reads the settle's result, and the else arm is the ordinary ingest.
        // #2760: the settle is the ENDING RUN's slot, not a fixed one, so a check settles the check slot's
        // results and a prep run falls through to the ingest below.
        #expect(body.contains("if let report = PrepQueueService.settleReachabilityProbe(slot: slot, into: context, now: Date())"))
        #expect(body.contains("ingestPrep()"))
    }
}
