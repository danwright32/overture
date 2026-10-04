import Testing
import Foundation

// #4444: no hosted suite puts its window ON SCREEN.
//
// WHY. Across the last 100 failed `swift-tests` runs on 2026-10-04, 24 were the test host dying, and 18
// of those died in the same place: `HostedWindowsAreReleasedTests.whichPartOfAHostedTestSurvivesIt()` was
// running, and the test that had just finished was, every single time,
// `HandedRowsStayLiveTests.aStoreChangeStillReachesAQueueThatNoLongerQueriesTheStore()`. That suite was
// the ONLY hosted test that ordered its window onto the screen (`makeKeyAndOrderFront`), and it returned
// the moment its rows were derived. An on-screen window's close is finished by the window server on later
// turns of the run loop, and the queue screen it held still had work scheduled; the next test to turn the
// run loop for a while runs all of it, after that test's container is gone. The crash series began on
// 2026-09-14, the day after that suite landed (08fe329f). It never crashed on Dan's Mac, which is why it
// was found from CI history rather than reproduced (40 local repetitions: 0 restarts).
//
// Every other hosted suite renders into a window that never reaches the screen, and they all derive and
// draw what they test, so nothing is lost by the rule. A source scan rather than a behavioural test,
// because the fault shows only as a host death in a LATER test on a slower machine, which no test of the
// suite itself can observe.
@Suite("Hosted suites keep their windows off screen (#4444)")
struct HostedWindowsStayOffScreenGuardTests {

    private static let roots = ["OvertureHostedTests"]

    // The floor `HostedContainersGoThroughTheHelperGuardTests` uses for the same tree (#2311).
    private static let floor = 20

    // Every AppKit call that puts a window on screen or makes it key, which is what hands its teardown
    // to the window server.
    private static let onScreen = ["makeKeyAndOrderFront", "orderFront", "orderFrontRegardless",
                                   "makeKeyWindow", "makeMain"]

    @Test func noHostedSuiteOrdersAWindowOnScreen() {
        let files = AppSourceWalk.files(underAll: Self.roots.map(RepoRoot.mac.appendingPathComponent),
                                        floor: Self.floor)
        var offenders: [String] = []
        for file in files {
            let code = SwiftSource.scannableLines(in: file.text).map(\.code).joined(separator: "\n")
            for call in Self.onScreen where code.contains(call + "(") {
                offenders.append("\(file.name): \(call)")
            }
        }
        #expect(files.count >= Self.floor,
                "the hosted test sources were not walked, so this guard checked nothing at all")
        #expect(offenders.isEmpty, Comment(rawValue:
                "these hosted suites put a window on screen, whose teardown then runs in whichever test "
                + "turns the run loop next, after its container is gone. That killed the CI test host in 18 "
                + "of the 24 host deaths found on 2026-10-04 (#4444). Render off screen instead: "
                + offenders.joined(separator: ", ")))
    }
}
