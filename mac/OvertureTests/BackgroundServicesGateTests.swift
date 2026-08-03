import Testing

// The unit suite boots the full Overture.app as its test host (TEST_HOST/BUNDLE_LOADER in
// project.yml), so the app's launch-time background work (scout, Gmail reply checks, draft
// prep, Downbeat export watching) would otherwise fire during every test run. That work hits
// the network and donates App Intents at launch, adding a ~30s startup stall to the suite (#195).
// AppEnvironment.shouldStartBackgroundServices is the gate RootView checks before starting any
// of it. This run is itself under XCTest, so the gate must be closed here.
@Suite("Background services gate")
struct BackgroundServicesGateTests {

    @Test func detectsThatItIsRunningUnderTests() {
        #expect(AppEnvironment.isRunningUnderTests)
    }

    @Test func skipsBackgroundServicesUnderTests() {
        #expect(AppEnvironment.shouldStartBackgroundServices == false,
                "Background services must stay off under XCTest so the suite doesn't pay the app's launch-time network/startup tax (#195).")
    }
}
