import Testing
import Foundation

// #1966: the Swift suite is hosted in the app, and the app is menu-bar-only (LSUIElement), so every
// test run depends on macOS finding room for a status item. On 2026-08-01 that stopped happening and
// the whole suite became unrunnable: 4811 tests, blocked by a menu bar.
//
// The app's own log, captured on a launch that vanished:
//
//   [com.apple.TCC:access] TCCAccessRequest service=kTCCServiceAccessibility, target_token={pid:1091}
//   [com.apple.FrontBoard:SceneClient] [com.apple.controlcenter:...] Received action(s): NSStatusItemChangeVisibilityAction
//   [com.apple.AppKit:StatusBar] 0 terminating on removal
//   [com.apple.AppKit:Application] terminate:
//
// A SwiftUI MenuBarExtra sets its status item to terminate the app when the item is REMOVED, and
// something on the machine (a window manager reaching in over Accessibility, a menu bar with no room
// left, a stray Cmd-drag) can make that happen a second after launch. The app then quits before
// XCTest finishes bootstrapping, which xcodebuild reports as "the test runner exited with code 0
// while preparing to run tests": no failure, no crash log, no named test, nothing to read.
//
// The test host has no use for a menu bar item. It never shows a menu, nobody clicks it, and Dan
// never sees it. So it does not ask for one, and a machine that cannot place one can no longer stop
// the suite from running. The real launch is untouched: the menu bar presence IS the app when the
// window is closed (#266).
@Suite("A test run does not depend on a menu bar slot (#1966)")
struct TestHostNeedsNoMenuBarTests {

    // Directly assertable, because this suite IS running under the test host: if the rule were
    // inverted, or read a value that is false here, this test states it plainly rather than proving
    // it by implication.
    @Test func theTestHostAsksForNoMenuBarItem() {
        #expect(AppEnvironment.isRunningUnderTests, "this suite runs in the host; the rest rests on it")
        #expect(AppEnvironment.showsMenuBarExtra == false)
    }

    // The other half, and the one that would break Dan's app if it were wrong: a real launch is a
    // menu-bar app and must stay one. Stated over the rule's inputs rather than over the live value,
    // which can only ever be the test one here.
    @Test func arealLaunchStillPlacesItsMenuBarItem() {
        #expect(AppEnvironment.showsMenuBarExtra(isRunningUnderTests: false))
        #expect(AppEnvironment.showsMenuBarExtra(isRunningUnderTests: true) == false)
    }

    // The guard and its wiring are two claims (#887). The rule is only true on screen if the scene
    // actually hands it to MenuBarExtra: without the argument the item is inserted unconditionally
    // and every test run goes back to depending on the menu bar, with this suite still green.
    @Test func theSceneHandsTheRuleToTheMenuBarItem() {
        let app = SourceGuardHelper.source("Overture/App/OvertureApp.swift")
        #expect(!app.isEmpty)
        #expect(app.contains("isInserted:"), "the item must be conditionally inserted")
        #expect(app.contains("AppEnvironment.showsMenuBarExtra"),
                "and the condition must be this rule, not one restated in the scene")
    }
}
