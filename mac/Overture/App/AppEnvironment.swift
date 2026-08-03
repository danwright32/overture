import Foundation

// #1967: lifted out of OvertureApp.swift, unchanged, because that file carries `@main` and is the one
// source the unhosted test target cannot compile into itself. Everything here is a plain answer about
// the process, needed by code the pure suite tests, so it has to live somewhere the app entry point
// does not. Same declarations, same behaviour; only the file changed.
enum AppEnvironment {
    static var isRunningUnderTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // The unit suite hosts itself in the full app (TEST_HOST/BUNDLE_LOADER), so launching for
    // a test run also boots the app's launch-time background work: scouting, Gmail reply
    // checks, reply classification, draft prep, and the Downbeat export watcher. That work
    // hits the network and donates App Intents at launch, adding a single ~30s startup stall
    // to every test run (#195). None of it is needed by the suite (tests build their own
    // in-memory stores and call the logic directly), so skip it under XCTest.
    //
    // #1967: still correct for the HOSTED target, which is the only one that launches the app at all.
    // The unhosted target never reaches this code path because nothing there starts the app.
    static var shouldStartBackgroundServices: Bool {
        !isRunningUnderTests
    }

    // #1966: whether this launch asks macOS for a menu bar item at all.
    //
    // The suite is hosted IN the app, so every test run launches it, and a SwiftUI MenuBarExtra sets
    // its status item to terminate the app when the item is REMOVED. Anything that removes the item
    // therefore kills the test host: a menu bar with no room left, a Cmd-drag, a window manager
    // reaching in over Accessibility. On 2026-08-01 that started happening on Dan's Mac and took the
    // entire suite with it (4811 tests), reported by xcodebuild only as "the test runner exited with
    // code 0 while preparing to run tests", with no failure, no crash log and no named test.
    //
    // The host has no use for the item: no menu is ever opened, and nobody sees it. So it does not ask
    // for one, and the machine's menu bar can no longer decide whether the suite runs. A REAL launch is
    // untouched, and must be: with the window closed, the menu bar presence IS the app (#266).
    static var showsMenuBarExtra: Bool { showsMenuBarExtra(isRunningUnderTests: isRunningUnderTests) }

    // Split from the live value so both answers are testable from inside the test host, where the live
    // one can only ever be the test answer.
    static func showsMenuBarExtra(isRunningUnderTests: Bool) -> Bool { !isRunningUnderTests }
}
