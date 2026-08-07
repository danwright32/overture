import Testing
import Foundation

// The Swift writer half of the Prep queue contract (#157). The READER is the Prep Claude Code
// workflow (docs/prep-runbook.md), not code, so there is no second programmatic side to assert —
// this fixture pins what PrepQueueBuilder.encode emits and is the canonical example the runbook
// points the workflow at. The committed fixture must decode to exactly the model the builder
// round-trips, so a change to PrepQueue's shape breaks this test instead of the workflow silently
// reading a work-list it no longer understands (the #109 class).
@Suite("Prep queue contract fixtures")
struct PrepQueueContractTests {
    private func fixtureDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("fixtures/prep-queue")
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureDirectory().appendingPathComponent(name))
    }

    private func fixtureFileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory().path)
            .filter { $0.hasSuffix(".json") }
    }

    // #491/#744: enumerates whatever is actually committed, so a new fixture file with no
    // matching decode case fails here instead of silently shipping with zero coverage on this side.
    @Test func decodesEveryCommittedFixtureWithoutThrowing() throws {
        let names = try fixtureFileNames()
        #expect(!names.isEmpty)
        for name in names {
            let data = try fixture(name)
            #expect(throws: Never.self) {
                try JSONDecoder().decode(PrepQueue.self, from: data)
            }
        }
    }

    // The exact model the v1 fixture encodes: one fully-populated item and one with every optional
    // omitted (decodes to nil), exercising both ends of the contract. v1 predates `production`
    // (#586), so it decodes to nil under the current model — the byte-identical backward-decode proof.
    private let expected = PrepQueue(
        version: 1,
        generatedAt: "2026-06-25T00:00:00.000Z",
        items: [
            PrepQueueItem(
                naturalKey: "aurora-strings|2026-03-10|carnegie-hall",
                groupName: "Aurora Strings",
                venue: "Carnegie Hall",
                performanceDate: "2026-03-10",
                discipline: "music",
                websiteURL: "https://aurorastrings.example",
                sourceListingURL: "https://example.org/aurora-10",
                possibleMatchName: "Aurora Strings",
                priorRelationship: "warm",
                production: nil
            ),
            PrepQueueItem(
                naturalKey: "lumen-dance|undated|none",
                groupName: "Lumen Dance",
                venue: nil,
                performanceDate: nil,
                discipline: "dance",
                websiteURL: nil,
                sourceListingURL: nil,
                possibleMatchName: nil,
                priorRelationship: "cold",
                production: nil
            ),
        ]
    )

    @Test func theCommittedFixtureMatchesWhatTheBuilderEncodes() throws {
        // The fixture decodes to exactly the model the builder writes, pinning the wire shape.
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture("v1.json"))
        #expect(decoded == expected)
    }

    @Test func builderOutputRoundTripsThroughTheReader() throws {
        // Encode via the real writer, decode back: the contract is symmetric for both optional ends.
        let data = try PrepQueueBuilder.encode(expected)
        let roundTripped = try JSONDecoder().decode(PrepQueue.self, from: data)
        #expect(roundTripped == expected)
    }

    @Test func theBuilderNowStampsVersion11() {
        let q = PrepQueueBuilder.build(from: [], generatedAt: "2026-06-25T00:00:00.000Z", houses: [])
        #expect(q.version == 11)
    }

    // v2 (#586): the queue item gains an optional `production` (self / agency / unknown, from
    // `Prospect.production`/#349), so the Prep research step knows whether a show is self-produced
    // before deciding whether to pursue a named performer directly (#366 Phase 3). Additive, so the
    // v1 fixture above still decodes with `production` absent (nil).
    @Test func theV2FixtureCarriesTheProductionType() throws {
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture("v2.json"))
        #expect(decoded.version == 2)
        #expect(decoded.items[0].production == "self")
        #expect(decoded.items[1].production == "agency")
    }

    // v3 (#367): the queue item gains an optional `reprepMode` ("draft_only" / "contacts_only",
    // absent means both), so the Prep run knows to skip the corresponding half for a prospect Dan
    // asked to re-prep. Additive, so the v1/v2 fixtures above still decode with it absent (nil).
    @Test func theV3FixtureCarriesTheReprepMode() throws {
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture("v3.json"))
        #expect(decoded.version == 3)
        #expect(decoded.items[0].reprepMode == "draft_only")
        #expect(decoded.items[1].reprepMode == "contacts_only")
    }

    // v4 (#1122): the queue item gains `runEndDate` (the run's closing night) and `openingNightPassed`
    // (true only for a run whose opening night has passed while later dates remain), so the Prep run can
    // pitch the whole run and never reference a gone opening night. Additive, so v1-v3 fixtures still
    // decode with both absent (nil).
    @Test func theV4FixtureCarriesTheRunRangeAndPassedOpening() throws {
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture("v4.json"))
        #expect(decoded.version == 4)
        #expect(decoded.items[0].runEndDate == "2026-03-14")
        #expect(decoded.items[0].openingNightPassed == true)
        // The second item is single-night with no passed opening: both fields absent.
        #expect(decoded.items[1].runEndDate == nil)
        #expect(decoded.items[1].openingNightPassed == nil)
    }

    // v5 (#5): the queue item gains an optional `experimentArmInstruction`, the opener archetype an A/B
    // experiment item must use (one of the four OpenerArchetype tokens), copied from the app-assigned
    // Prospect.assignedArm. Additive, so v1-v4 fixtures still decode with it absent (nil).
    @Test func theV5FixtureCarriesTheExperimentArmInstruction() throws {
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture("v5.json"))
        #expect(decoded.version == 5)
        #expect(decoded.items[0].experimentArmInstruction == "credential-first")
        // The second item is not under an experiment: the field is absent.
        #expect(decoded.items[1].experimentArmInstruction == nil)
    }

    // v6 (#1597): a reachability check's item gains `alsoAnswersFor`, the other shows one research pass
    // answers for, so a producer is researched once rather than once per show (about $1.36 each). Additive,
    // so v1-v5 fixtures still decode with it absent (nil).
    @Test func theV6FixtureCarriesTheShowsOneAnswerCovers() throws {
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture("v6.json"))
        #expect(decoded.version == 6)
        #expect(decoded.items[0].alsoAnswersFor == ["aurora-strings|2026-03-11|merkin-hall",
                                                    "aurora-strings|2026-03-12|the-town-hall"])
        // The second item stands alone (a one-off hunt, or a normal Prep item): the field is absent.
        #expect(decoded.items[1].alsoAnswersFor == nil)
    }

    // Every older fixture must still decode, because the field is additive and an old queue file left on
    // disk by a previous version must not become unreadable.
    @Test func everyEarlierFixtureStillDecodesWithNoCoveredShows() throws {
        for name in ["v1.json", "v2.json", "v3.json", "v4.json", "v5.json"] {
            let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture(name))
            #expect(decoded.items.allSatisfy { $0.alsoAnswersFor == nil }, "\(name) should carry no group")
        }
    }

    // v7 (#1720): the queue gains a RUN-LEVEL `houses`, the organisations the app has already judged to be
    // the building rather than the act. It sits beside `items`, not inside them, because it is one answer
    // about the whole store rather than a fact about any one show. Each entry carries the gate's folded
    // `key` and one readable `name`, so a run comparing a name it read on a page can match either.
    @Test func theV7FixtureCarriesTheHouseList() throws {
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture("v7.json"))
        #expect(decoded.version == 7)
        #expect(decoded.houses?.map(\.key) == ["abrons arts center", "carnegie hall presents",
                                               "under st marks"])
        #expect(decoded.houses?.map(\.name) == ["Abrons Arts Center", "Carnegie Hall Presents",
                                                "Under St Marks"])
    }

    // Additive, so a queue file written before this phase still decodes. An old file left on disk must not
    // become unreadable, and an ABSENT list is not an empty one: absent means the file predates the field,
    // which is a different thing from a store that named no houses.
    @Test func everyEarlierFixtureStillDecodesWithNoHouseList() throws {
        for name in ["v1.json", "v2.json", "v3.json", "v4.json", "v5.json", "v6.json"] {
            let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture(name))
            #expect(decoded.houses == nil, "\(name) should carry no house list")
        }
    }

    // v8 (#1824): each item may carry what its own listing page says, read by the app because the detached
    // run's tool scope cannot render a JavaScript-drawn page. Three states, and the fixture carries all of
    // them, because the run says a different sentence about each: `read` with the page's text, `unreadable`
    // (a page we could not read, which is NOT a show with no description), and absent (there was no page
    // to look at).
    @Test func theV8FixtureCarriesWhatTheListingPageSays() throws {
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture("v8.json"))
        #expect(decoded.version == 8)
        #expect(decoded.items[0].showListing?.status == ShowListing.read)
        #expect(decoded.items[0].showListing?.url == "https://example.org/aurora-10")
        #expect(decoded.items[0].showListing?.text?.contains("string quartet") == true)
        #expect(decoded.items[0].showListing?.truncated == nil)
        #expect(decoded.items[1].showListing?.status == ShowListing.unreadable)
        #expect(decoded.items[1].showListing?.text == nil)
        #expect(decoded.items[2].showListing == nil)
    }

    // v9 (#1856): an item may say that nobody but the ACT is named on this show, which is what tells the
    // run to pursue the act instead of researching a producing organisation that does not exist.
    //
    // Absent is not false. A file written before this field, or an item the app judged to name a producer,
    // both leave it out, and only the second is a claim; the run treats a missing field as "nothing said"
    // and behaves exactly as it always did.
    @Test func theV9FixtureSaysWhenNobodyButTheActIsNamed() throws {
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture("v9.json"))
        #expect(decoded.version == 9)
        #expect(decoded.items[1].onlyTheActIsNamed == true)
        #expect(decoded.items[0].onlyTheActIsNamed == nil)
    }

    // v10 (#1887): an item may say how well Dan already knows the ROOM, as one of three bands and never
    // a count. The band is the whole payload on purpose: Dan's rule is "never an exact number", and the
    // way to stop the drafter stating one is to send it nothing to state (L27).
    @Test func theV10FixtureCarriesTheVenueHistoryBand() throws {
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture("v10.json"))
        #expect(decoded.version == 10)
        #expect(decoded.items[1].venueHistory == "a_few")

        // The Carnegie item deliberately carries NOTHING, even though Dan has shot Carnegie well over a
        // hundred times. The runbook already requires a Carnegie show to lead with the tenure credential,
        // which is about that same room, so a band beside it would be one fact stated twice (Dan's call,
        // 2026-07-31). Absent here is a decision, not a gap.
        #expect(decoded.items[0].venue == "Carnegie Hall")
        #expect(decoded.items[0].venueHistory == nil)
    }

    // v11 (#2259): an item may name the producing company its own listing page credits in front of the
    // show's title. It rides WITH `onlyTheActIsNamed`, deliberately: that flag means the stored presenter
    // field is empty, and this field is the app saying the page names a company anyway, which is exactly
    // the pair the runbook used to get wrong by treating the first as a claim about the page.
    @Test func theV11FixtureNamesTheCompanyTheListingCredits() throws {
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture("v11.json"))
        #expect(decoded.version == 11)
        #expect(decoded.items[1].onlyTheActIsNamed == true)
        #expect(decoded.items[1].organisationNamedOnListing == "Fenwick Productions")
        #expect(decoded.items[0].organisationNamedOnListing == nil)
    }

    // The claim the field exists to make, end to end: the app READS that name off the page text rather
    // than the fixture merely asserting a string it was handed. A fixture pinning a value nobody derives
    // is a test of its own typing (L1).
    @Test func attachingReadsTheCreditOffTheListingText() throws {
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture("v11.json"))
        let stripped = PrepQueue(version: decoded.version, generatedAt: decoded.generatedAt,
                                 items: decoded.items.map { item in
                                     var copy = item
                                     copy.showListing = nil
                                     copy.organisationNamedOnListing = nil
                                     return copy
                                 }, houses: decoded.houses)
        let listings = Dictionary(uniqueKeysWithValues: decoded.items.compactMap { item in
            item.showListing.map { (item.naturalKey, $0) }
        })
        let rebuilt = PrepQueueBuilder.attaching(listings, to: stripped)
        #expect(rebuilt.items[1].organisationNamedOnListing == "Fenwick Productions")
        #expect(rebuilt.items[0].organisationNamedOnListing == nil)
    }

    // Additive: an earlier queue file decodes as having said NOTHING about the venue, which the runbook
    // reads as "say nothing", never as "he has never shot there".
    @Test func everyEarlierFixtureStillDecodesWithNoVenueHistory() throws {
        for name in ["v1.json", "v2.json", "v3.json", "v4.json", "v5.json", "v6.json", "v7.json",
                     "v8.json", "v9.json"] {
            let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture(name))
            #expect(decoded.items.allSatisfy { $0.venueHistory == nil },
                    "\(name) should carry no venue history")
        }
    }

    // The same additive promise the house list made: a queue file written before this field still decodes,
    // and reads as having said nothing about it rather than as a show that names a producer.
    @Test func everyEarlierFixtureStillDecodesWithNoActNamingClaim() throws {
        for name in ["v1.json", "v2.json", "v3.json", "v4.json", "v5.json", "v6.json", "v7.json",
                     "v8.json"] {
            let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture(name))
            #expect(decoded.items.allSatisfy { $0.onlyTheActIsNamed == nil },
                    "\(name) should carry no act-naming claim")
        }
    }

    // Additive, so every earlier queue file still decodes. Absent is not the same answer as `unreadable`:
    // absent means the app never looked (no listing URL, or a file written before this field), and a run
    // that read the two as the same thing would report "we could not read the page" about shows that never
    // had one.
    @Test func everyEarlierFixtureStillDecodesWithNoShowListing() throws {
        for name in ["v1.json", "v2.json", "v3.json", "v4.json", "v5.json", "v6.json", "v7.json"] {
            let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture(name))
            #expect(decoded.items.allSatisfy { $0.showListing == nil }, "\(name) should carry no listing")
        }
    }

    // MARK: - Negative paths (#747)
    //
    // The enumeration guard only proves every committed fixture decodes. A guard that cannot fail is
    // not a guard, so these prove a DRIFTED fixture would actually be caught rather than waved
    // through. The app writes this file, so the risk is not a hostile input: it is a fixture quietly
    // losing a field that the Prep run (a Claude Code workflow, not code) depends on, with the guard
    // reporting green the whole time.

    private func decoding(_ json: String) throws -> PrepQueue {
        try JSONDecoder().decode(PrepQueue.self, from: Data(json.utf8))
    }

    // naturalKey is the OPAQUE token the run must echo back verbatim into PrepResults; rebuilding it
    // is the documented silent-mismatch trap. An item without one is unusable.
    @Test func anItemMissingItsNaturalKeyIsRejected() {
        let keyless = """
        {"version":3,"generatedAt":"now","items":[
          {"groupName":"G","discipline":"music","priorRelationship":"none"}]}
        """
        #expect(throws: (any Error).self) { try decoding(keyless) }
    }

    @Test func anItemMissingARequiredResearchFieldIsRejected() {
        // groupName is what the Prep run actually researches; without it the item is a dead token.
        let nameless = """
        {"version":3,"generatedAt":"now","items":[
          {"naturalKey":"k","discipline":"music","priorRelationship":"none"}]}
        """
        #expect(throws: (any Error).self) { try decoding(nameless) }
    }

    // production and reprepMode are genuinely optional (v2/v3 additions), so their absence must NOT
    // be an error. This pins the line between "optional by design" and "missing and broken".
    @Test func theOptionalV2AndV3FieldsMayBeAbsent() throws {
        let minimal = """
        {"version":3,"generatedAt":"now","items":[
          {"naturalKey":"k","groupName":"G","discipline":"music","priorRelationship":"none"}]}
        """
        let decoded = try decoding(minimal)
        #expect(decoded.items[0].production == nil)
        #expect(decoded.items[0].reprepMode == nil)
        // v4 (#1122) fields are optional too: a minimal item omits them and decodes to nil.
        #expect(decoded.items[0].runEndDate == nil)
        #expect(decoded.items[0].openingNightPassed == nil)
    }

    @Test func garbageIsRejectedRatherThanReadAsAnEmptyQueue() {
        #expect(throws: (any Error).self) { try decoding("not json") }
    }
}
