import Testing
import Foundation
import SwiftData
@testable import Overture

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

    // An incomplete count must never claim a run was fine. It cannot say how many calls there were, so it
    // says nothing rather than reporting a partial figure as the run's total.
    @Test func anIncompleteCountMakesNoClaimEitherWay() {
        var outcome = PrepImporter.Outcome()
        outcome.webCalls = PrepResults.WebCalls(recorded: false, total: nil, items: 2, capPerItem: 15,
                                                allowance: 30, overCap: nil)
        #expect(PrepRunSummary.notes(for: outcome).contains { $0.contains("web") } == false)
    }
}
