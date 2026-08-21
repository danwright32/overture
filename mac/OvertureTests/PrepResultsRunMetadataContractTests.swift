import Testing
import Foundation

// #1678: the three top-level keys `prep-run.sh` adds to the prep results file after the workflow has
// finished with it, pinned as part of the contract they belong to.
//
// `model` (#1533), `runCost` (#1593) and `webCalls` (#1864) are written by `lib/models.sh`, not by the
// Prep workflow, so they arrived on a versioned cross-language file without a row in docs/contracts.md
// and without appearing in any fixture. Nothing pinned their shape.
//
// The shape that must not be got wrong is the honest/partial split, and it is the same split three times:
//
//   runCost   recorded: true  carries `usd` and `durationMs`
//             recorded: false carries NEITHER, only `partialUsd` and `partialDurationMs`
//   webCalls  recorded: true  carries `total`
//             recorded: false carries NEITHER, only `partialTotal`
//
// That absence is deliberate and load-bearing. A reader that reaches for the field it always reads gets
// nothing rather than a partial figure presented as the real one, which is exactly how a spend brake gets
// sized against a number nobody measured. #1616 and #1625 are about to build on `runCost.durationMs`,
// which is why this is pinned before they do.
@Suite("The run metadata on the prep results contract (#1678)")
struct PrepResultsRunMetadataContractTests {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = RepoRoot.url.appendingPathComponent("fixtures/prep-results/\(name)")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private func complete() throws -> [String: Any] { try fixture("run-metadata-complete-v8.json") }
    private func partial() throws -> [String: Any] { try fixture("run-metadata-partial-v8.json") }

    // #2311: every assertion below reads a nested dictionary, and a missing one would make each of them
    // vacuously true. So the fixtures are proved to carry all three keys before anything is judged.
    @Test func bothFixturesCarryAllThreeMetadataKeys() throws {
        for file in [try complete(), try partial()] {
            #expect(file["model"] != nil, "the model stamp is missing from a run metadata fixture")
            #expect(file["runCost"] != nil, "runCost is missing from a run metadata fixture")
            // #3004: and the two provenance keys, on BOTH fixtures. They sit at the top level rather than
            // inside `runCost` precisely so the PARTIAL fixture carries them too: a run whose cost could
            // not be read still knows what it was.
            #expect(file["runKind"] as? String == "check",
                    "runKind is missing from a run metadata fixture")
            #expect(file["runSlot"] as? String == "check",
                    "runSlot is missing from a run metadata fixture")
            #expect(file["webCalls"] != nil, "webCalls is missing from a run metadata fixture")
            #expect(file["results"] != nil, "the metadata must sit on a real results file, not alone")
        }
    }

    @Test func aCompleteRunCostCarriesTheFigureAndSaysSo() throws {
        let cost = try #require(try complete()["runCost"] as? [String: Any])

        #expect(cost["recorded"] as? Bool == true)
        #expect(cost["usd"] as? Double == 5.395423)
        #expect(cost["durationMs"] as? Int == 389_906)
        #expect(cost["streams"] as? Int == 3)
    }

    // The one that matters. A run whose streams did not all report has NO usd key at all, so a reader
    // reaching for the field it always reads finds nothing rather than a part of the total.
    @Test func anIncompleteRunCostPublishesNoTotalAtAll() throws {
        let cost = try #require(try partial()["runCost"] as? [String: Any])

        #expect(cost["recorded"] as? Bool == false)
        #expect(cost["usd"] == nil, "a partial reading must not present itself as the run's cost")
        #expect(cost["durationMs"] == nil, "a partial reading must not present itself as the run's duration")
        #expect(cost["partialUsd"] as? Double == 3.600917)
        #expect(cost["partialDurationMs"] as? Int == 389_906)
        #expect(cost["streamsRecorded"] as? Int == 2)
        #expect(cost["streams"] as? Int == 3)
    }

    @Test func aCompleteWebCallCountCarriesTheTotal() throws {
        let calls = try #require(try complete()["webCalls"] as? [String: Any])
        let byRoute = try #require(calls["byRoute"] as? [String: Any])

        #expect(calls["recorded"] as? Bool == true)
        #expect(calls["total"] as? Int == 59)
        #expect(calls["partialTotal"] == nil)
        #expect(byRoute["fetch"] as? Int == 28)
        #expect(byRoute["search"] as? Int == 31)
        // Every route is published even at zero, so a reader never has to tell "none" from "absent".
        #expect(byRoute["browser"] as? Int == 0)
        #expect(byRoute["bash"] as? Int == 0)
    }

    @Test func anIncompleteWebCallCountPublishesNoTotalAtAll() throws {
        let calls = try #require(try partial()["webCalls"] as? [String: Any])

        #expect(calls["recorded"] as? Bool == false)
        #expect(calls["total"] == nil, "a partial count must not present itself as the run's total")
        #expect(calls["partialTotal"] as? Int == 40)
        #expect(calls["streamsReported"] as? Int == 2)
        #expect(calls["streams"] as? Int == 3)
    }

    // #1835: refusals are counted in their own right, and they follow the SAME honest/partial split as the
    // total, for the same reason. A refused call reached nothing, so it must not be inside `total`, and one
    // stream's refusals must not be readable as the run's by a reader reaching for `denied`.
    @Test func refusalsAreCountedSeparatelyAndSplitTheSameWay() throws {
        let completeCalls = try #require(try complete()["webCalls"] as? [String: Any])
        let partialCalls = try #require(try partial()["webCalls"] as? [String: Any])
        let completeRefused = try #require(completeCalls["deniedByRoute"] as? [String: Any])
        let partialRefused = try #require(partialCalls["deniedByRoute"] as? [String: Any])

        #expect(completeCalls["denied"] as? Int == 0)
        #expect(completeCalls["partialDenied"] == nil)
        #expect(partialCalls["denied"] == nil,
                "a partial refusal count must not present itself as the run's own")
        #expect(partialCalls["partialDenied"] as? Int == 0)
        // Every route present at zero on both, so a reader never has to tell "none refused" from "this
        // writer did not look".
        for route in ["fetch", "search", "browser", "bash"] {
            #expect(completeRefused[route] as? Int == 0)
            #expect(partialRefused[route] as? Int == 0)
        }
    }

    // `overCap` is a VERDICT, not a count, and it is published on the incomplete path only when the
    // partial count already exceeds the allowance, because that verdict can only get truer. The complete
    // fixture is over its allowance and says so; the partial one is under it and stays silent rather than
    // claiming a run is within a limit it has not finished measuring.
    @Test func theOverCapVerdictIsOnlyPublishedWhenItCanBeTrusted() throws {
        let completeCalls = try #require(try complete()["webCalls"] as? [String: Any])
        let partialCalls = try #require(try partial()["webCalls"] as? [String: Any])

        #expect(completeCalls["overCap"] as? Bool == true)
        #expect(completeCalls["allowance"] as? Int == 45)
        #expect(partialCalls["overCap"] == nil,
                "an unfinished count that is under the allowance must not claim the run stayed under it")
    }

    // The metadata rides on a real results file and does not disturb it, so the app's decoder ignores all
    // three keys rather than failing on them. This is what makes them safely additive.
    @Test func theAppStillDecodesAResultsFileCarryingAllThree() throws {
        for name in ["run-metadata-complete-v8.json", "run-metadata-partial-v8.json"] {
            let url = RepoRoot.url.appendingPathComponent("fixtures/prep-results/\(name)")
            let data = try Data(contentsOf: url)
            let results = try PrepResultsDecoder.decode(data)
            #expect(!results.results.isEmpty, "\(name) must carry real results, not just metadata")
        }
    }
}
