import Foundation
import Testing

// #1967: the pure suite must not be hosted in Overture.app.
//
// Every Swift test used to run inside the launched app (TEST_HOST/BUNDLE_LOADER), so a fault that
// stopped the app staying open took ALL of them with it. That happened on 2026-08-01: a crowded menu
// bar removed the status item, SwiftUI's MenuBarExtra terminates the process when its item is removed,
// and xcodebuild reported only "the test runner exited with code 0 while preparing to run tests", with
// no failure, no crash log and no named test. Nothing in the Mac app could be verified at all, and since
// #1347 that local run is the ONLY verification a Swift change ever gets.
//
// #1966 closed that particular hole (the host no longer asks for a menu bar item). This closes the
// class: a launch fault of ANY kind must cost the handful of tests that genuinely need a running app,
// never the whole suite.
//
// Asserted from the RUNNING PROCESS rather than by reading project.yml, because the build setting is
// not the claim. The claim is that these tests are executing outside the app, and only the process can
// answer that. Under a hosted run Bundle.main IS the host app, so this test is red until the target is
// genuinely unhosted; under an unhosted run it is xctest's own tool.
@Suite("Unhosted test target")
struct UnhostedTestTargetTests {

    @Test func thePureSuiteDoesNotRunInsideTheApp() {
        let host = Bundle.main.bundleIdentifier ?? "(none)"
        #expect(!host.hasPrefix("com.danwright.overture"),
                """
                This suite is hosted in the app (Bundle.main is \(host)), so any fault that stops \
                Overture launching takes every test in it down at once, reported only as a runner that \
                exited while preparing to run tests. The pure suite must run in its own unhosted bundle.
                """)
    }
}
