import Testing
import Foundation
import SwiftData

// #1721: the run's real web-call count, read by the app rather than left in a file nobody opens.
//
// The runbook states a hop cap. A rule that lives only in a prompt is a hope (L27), and the event stream
// the runner has written since #1593 had no reader at all, so the cap had never once been checked. The
// script side now counts it; this is the half that gets the number in front of Dan.
@MainActor
@Suite("The app reads what the run actually spent on the web (#1721)")
struct PrepWebCallCountTests {

    private func results(_ block: String) throws -> PrepResults {
        let json = """
        {"version": 7, "generatedAt": "2026-07-29T00:00:00Z", "results": [], \(block)}
        """
        return try PrepResultsDecoder.decode(Data(json.utf8))
    }

    @Test func aRunsWebCallCountIsRead() throws {
        let r = try results("""
        "webCalls": {"recorded": true, "total": 47, "items": 2, "capPerItem": 15,
                     "allowance": 30, "overCap": true, "streams": 1,
                     "byRoute": {"fetch": 20, "search": 20, "browser": 5, "bash": 2}}
        """)
        #expect(r.webCalls?.total == 47)
        #expect(r.webCalls?.overCap == true)
        #expect(r.webCalls?.items == 2)
    }

    // A results file from before this existed must still decode and still land Dan's drafts. A gap in the
    // record is never a reason to drop his work on the floor, which is the same rule `model` follows.
    @Test func aResultsFileWithNoCountStillDecodes() throws {
        let r = try results("\"model\": \"sonnet\"")
        #expect(r.webCalls == nil)
        #expect(r.model == "sonnet")
    }

    // A run whose streams did not all report publishes no total at all, so the app must not invent one.
    // Reading a partial count as the real one is how a ceiling gets sized against a number nobody
    // measured, which is the exact mistake record_run_cost was written to avoid for money.
    @Test func anIncompleteCountIsNotReadAsATotal() throws {
        let r = try results("""
        "webCalls": {"recorded": false, "items": 1, "capPerItem": 15, "allowance": 15,
                     "streams": 2, "streamsReported": 1, "partialTotal": 9,
                     "byRoute": {"fetch": 5, "search": 4, "browser": 0, "bash": 0}}
        """)
        #expect(r.webCalls?.recorded == false)
        #expect(r.webCalls?.total == nil)
    }

    // The note only fires when the run went over. A cap that speaks on an ordinary run is an alert that
    // cries wolf (L36), and Dan's measured normal is 5 to 9 calls per show against a cap of 15.
    @Test func anOrdinaryRunSaysNothingAboutItsWebCalls() {
        var outcome = PrepImporter.Outcome()
        outcome.webCalls = PrepResults.WebCalls(recorded: true, total: 18, items: 2, capPerItem: 15,
                                                allowance: 30, overCap: false)
        #expect(PrepRunSummary.notes(for: outcome).contains { $0.contains("web") } == false)
    }

    @Test func aRunThatWentOverItsAllowanceSaysSo() {
        var outcome = PrepImporter.Outcome()
        outcome.webCalls = PrepResults.WebCalls(recorded: true, total: 47, items: 2, capPerItem: 15,
                                                allowance: 30, overCap: true)
        let note = PrepRunSummary.notes(for: outcome).first { $0.contains("web") }
        #expect(note == "47 web lookups for 2 shows, more than expected")
    }

    // The count must survive the trip from the FILE to the summary, through the importer the app really
    // calls. The first version of this test set the field by hand and passed with the wiring deleted,
    // which is the whole defect it was meant to catch: a rule and its wiring are two claims (L3), and a
    // test that assembles the wiring itself only ever proves the rule.
    @Test func theCountReachesTheSummaryThroughTheRealImporter() throws {
        let ctx = ModelContext(try ModelContainer(
            for: AppSchema.schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prep-results-\(UUID().uuidString).json")
        try """
        {"version": 7, "generatedAt": "2026-07-29T00:00:00Z", "results": [],
         "webCalls": {"recorded": true, "total": 47, "items": 2, "capPerItem": 15,
                      "allowance": 30, "overCap": true, "streams": 1}}
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let outcome = PrepImporter.consumeIfNew(
            at: url, into: ctx,
            defaults: UserDefaults(suiteName: "PrepWebCalls-\(UUID().uuidString)")!)

        #expect(outcome?.webCalls?.total == 47)
        #expect(PrepRunSummary.notes(for: outcome ?? PrepImporter.Outcome())
            .contains("47 web lookups for 2 shows, more than expected"))
    }

    // A single-show run says "1 show", not "1 shows". Caught by reading the generated copy inventory cold,
    // which is the only thing that can catch it: every test above used a two-show run, so the plural was
    // correct in each of them and the suite was green with the sentence broken.
    @Test func aSingleShowRunIsNotDescribedAsShows() {
        var outcome = PrepImporter.Outcome()
        outcome.webCalls = PrepResults.WebCalls(recorded: true, total: 40, items: 1, capPerItem: 15,
                                                allowance: 15, overCap: true)
        #expect(PrepRunSummary.notes(for: outcome)
            .contains("40 web lookups for 1 show, more than expected"))
    }

    // #1864: a run whose shows named more people than there were shows says so, because "more than
    // expected" is measured against an allowance sized by the PEOPLE and Dan can see only the shows. A
    // cabaret room booking five-handers is the case: two shows, six people, and a figure judged against
    // six but explained by two reads as a run that spent three times what it should.
    @Test func aRunCoveringMorePeopleThanShowsSaysHowManyPeople() {
        var outcome = PrepImporter.Outcome()
        outcome.webCalls = PrepResults.WebCalls(recorded: true, total: 100, items: 2, parties: 6,
                                                capPerItem: 15, allowance: 90, overCap: true)
        let note = PrepRunSummary.notes(for: outcome).first { $0.contains("web") }
        #expect(note == "100 web lookups for 2 shows, 6 people to find, more than expected")
    }

    // And the ordinary run, where every show was one party, says exactly what it always said. A sentence
    // that grows a clause on every run is a sentence Dan stops reading.
    @Test func aRunWhereEveryShowWasOnePartyKeepsTheShorterSentence() {
        var outcome = PrepImporter.Outcome()
        outcome.webCalls = PrepResults.WebCalls(recorded: true, total: 47, items: 2, parties: 2,
                                                capPerItem: 15, allowance: 30, overCap: true)
        #expect(PrepRunSummary.notes(for: outcome)
            .contains("47 web lookups for 2 shows, more than expected"))
    }

    // A results file written before the party count existed still reads, and still says something true.
    @Test func aRunFromBeforeThePartyCountStillReads() {
        var outcome = PrepImporter.Outcome()
        outcome.webCalls = PrepResults.WebCalls(recorded: true, total: 47, items: 2, capPerItem: 15,
                                                allowance: 30, overCap: true)
        #expect(outcome.webCalls?.parties == nil)
        #expect(PrepRunSummary.notes(for: outcome)
            .contains("47 web lookups for 2 shows, more than expected"))
    }

    // An incomplete count must never claim a run was fine. It cannot say how many calls there were, so it
    // says nothing rather than reporting a partial figure as the run's total.
    @Test func anIncompleteCountMakesNoClaimEitherWay() {
        var outcome = PrepImporter.Outcome()
        outcome.webCalls = PrepResults.WebCalls(recorded: false, total: nil, items: 2, capPerItem: 15,
                                                allowance: 30, overCap: nil)
        #expect(PrepRunSummary.notes(for: outcome).contains { $0.contains("web") } == false)
    }

    // #1835: a call the permission layer REFUSED never reached anything. The script no longer counts one
    // as reach, and the refusals it counts separately need a reader here, or the field is written and
    // never read (L46) and a run blocked at every attempt looks identical to one that never needed the
    // web. That mattered concretely: the first diagnosis of #1824 read a refused browser call as evidence
    // the run HAD browser access.
    @Test func aRunWhoseLookupsWereRefusedSaysSo() {
        var outcome = PrepImporter.Outcome()
        outcome.webCalls = PrepResults.WebCalls(recorded: true, total: 6, denied: 2, items: 1,
                                                capPerItem: 15, allowance: 15, overCap: false)
        #expect(PrepRunSummary.notes(for: outcome)
            .contains("2 web lookups refused, that research never happened"))
    }

    // One refusal is one lookup. Same plural trap the "1 show" sentence fell into, and the same reason it
    // is worth a test of its own: every other case here uses more than one.
    @Test func aSingleRefusalIsNotDescribedAsLookups() {
        var outcome = PrepImporter.Outcome()
        outcome.webCalls = PrepResults.WebCalls(recorded: true, total: 6, denied: 1, items: 1,
                                                capPerItem: 15, allowance: 15, overCap: false)
        #expect(PrepRunSummary.notes(for: outcome)
            .contains("1 web lookup refused, that research never happened"))
    }

    // The ordinary run is silent. Refusals are rare, and a sentence that appears when nothing was refused
    // is an alert nobody reads by the time one is (L36).
    @Test func aRunWithNothingRefusedSaysNothingAboutRefusals() {
        var outcome = PrepImporter.Outcome()
        outcome.webCalls = PrepResults.WebCalls(recorded: true, total: 18, denied: 0, items: 2,
                                                capPerItem: 15, allowance: 30, overCap: false)
        #expect(PrepRunSummary.notes(for: outcome).contains { $0.contains("refused") } == false)
    }

    // A results file written before refusals were counted carries no `denied` at all, and absent is not
    // zero: it means nobody looked. It must still decode, and must not be reported as a run with none.
    @Test func aRunFromBeforeRefusalsWereCountedStillReads() {
        var outcome = PrepImporter.Outcome()
        outcome.webCalls = PrepResults.WebCalls(recorded: true, total: 47, items: 2, capPerItem: 15,
                                                allowance: 30, overCap: true)
        #expect(outcome.webCalls?.denied == nil)
        #expect(PrepRunSummary.notes(for: outcome).contains { $0.contains("refused") } == false)
    }

    // The incomplete path publishes `partialDenied` and no `denied` at all, for the same reason it
    // publishes no `total`. The app must find nothing rather than read one stream's refusals as the run's.
    @Test func anIncompleteCountSaysNothingAboutRefusals() throws {
        let r = try results("""
        "webCalls": {"recorded": false, "items": 1, "capPerItem": 15, "allowance": 15,
                     "streams": 2, "streamsReported": 1, "partialTotal": 9, "partialDenied": 4,
                     "byRoute": {"fetch": 5, "search": 4, "browser": 0, "bash": 0},
                     "deniedByRoute": {"fetch": 0, "search": 0, "browser": 4, "bash": 0}}
        """)
        #expect(r.webCalls?.denied == nil)
        var outcome = PrepImporter.Outcome()
        outcome.webCalls = r.webCalls
        #expect(PrepRunSummary.notes(for: outcome).contains { $0.contains("refused") } == false)
    }

    // And the whole way through, from the file the runner writes to the sentence Dan reads. Setting the
    // field by hand would prove the rule and nothing about the wiring (L3).
    @Test func theRefusalCountReachesTheSummaryThroughTheRealImporter() throws {
        let ctx = ModelContext(try ModelContainer(
            for: AppSchema.schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prep-results-\(UUID().uuidString).json")
        try """
        {"version": 7, "generatedAt": "2026-07-29T00:00:00Z", "results": [],
         "webCalls": {"recorded": true, "total": 4, "denied": 2, "items": 1, "capPerItem": 15,
                      "allowance": 15, "overCap": false, "streams": 1,
                      "deniedByRoute": {"fetch": 0, "search": 0, "browser": 2, "bash": 0}}}
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let outcome = PrepImporter.consumeIfNew(
            at: url, into: ctx,
            defaults: UserDefaults(suiteName: "PrepWebCalls-\(UUID().uuidString)")!)

        #expect(outcome?.webCalls?.denied == 2)
        #expect(PrepRunSummary.notes(for: outcome ?? PrepImporter.Outcome())
            .contains("2 web lookups refused, that research never happened"))
    }
}
