import Testing
import Foundation
@testable import Overture

// #849: the test suite was writing into Dan's real handoff directory and launching real, token-spending
// `claude -p` runs.
//
// Found by walking the app with him: his Debug handoff folder held `overture-scout-page-fine.html`, a
// pinned listings page for a source called "fine": a name that exists nowhere in the app, only in a
// test. Those tests called runScout injecting the extractor and the fetch but NOT the pin and the
// launch, so both defaulted to the real thing. Every run of the suite, including CI, pinned a page into
// the live directory, wrote a real queue file, and fired a real Claude run. It also left a stale results
// file behind, which is what then hung the Add-a-lead sheet on a source it had never asked about.
//
// Injecting the seams in those tests fixes the instances. This fixes the CLASS: the launcher and the
// pin refuse outright under test, so the next test that forgets cannot do it again. Careful injection at
// every call site is not a guarantee, it is a promise, and this one was already broken.
@MainActor
@Suite("A test can never launch a real run or write to the real store (#849)")
struct TestsNeverTouchTheRealStoreTests {
    private func item() -> ScoutExtractQueueItem {
        ScoutExtractQueueItem(sourceId: "would-be-real", orgName: "Org",
                              listingsURL: "https://org.example/events",
                              pagePath: "/tmp/page.html")
    }

    // THE test. We are, right now, inside the test suite. So this must refuse, and it must refuse loudly
    // rather than quietly doing nothing: a silent no-op would let a test believe it had launched a run
    // and then assert against a results file it never asked for.
    @Test func launchingAnExtractRunIsRefusedUnderTest() {
        #expect(throws: ScoutExtractService.ExtractLaunchError.refusedUnderTest) {
            _ = try ScoutExtractService.startExtract(items: [item()], now: Date())
        }
    }

    // And nothing is left behind. Not a marker (the app would think a run was live), and NOT a queue
    // file: a stale one of those, written by a test, is exactly what later hung Dan's Add-a-lead sheet on
    // a source it had never asked about. So the refusal has to come before the write, not after it.
    @Test func aRefusedLaunchLeavesNoTraceInTheHandoffDirectory() throws {
        let queue = ScoutExtractQueueBuilder.defaultURL
        let queueBefore = try? Data(contentsOf: queue)

        _ = try? ScoutExtractService.startExtract(items: [item()], now: Date())

        #expect(FileManager.default.fileExists(atPath: ScoutExtractService.defaultMarkerURL.path) == false)
        // Byte-identical: the suite did not touch the live queue file, whatever was or was not in it.
        #expect((try? Data(contentsOf: queue)) == queueBefore)
    }

    // The pin is the other half: it wrote a real HTML file into the directory the running app reads.
    @Test func pinningAPageIsRefusedUnderTest() {
        let page = FetchedPage(normalizedHTML: "<p>listings</p>",
                               finalURL: "https://org.example/events", contentHash: "h")

        #expect(throws: ScoutPagePin.PinError.refusedUnderTest) {
            _ = try ScoutPagePin.write(page, forSourceId: "would-be-real")
        }
        #expect(FileManager.default.fileExists(
            atPath: ScoutPagePin.url(forSourceId: "would-be-real").path) == false)
    }

    // The guard has to be the REAL condition, not a flag a test could set. If this ever reads false
    // inside the suite, both guards above are dead and neither would fail: they would simply stop
    // guarding, silently, which is exactly how the original bug survived a full day of green runs.
    @Test func theSuiteKnowsItIsTheSuite() {
        #expect(AppEnvironment.isRunningUnderTests)
    }
}
