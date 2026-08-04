import Testing
import AppKit

// #2088: closing the main window terminated the whole app, menu bar item and all, so the resident
// half of the product (reply and bounce detection, calendar conflict rechecks, booking
// reconciliation, away alerts) silently stopped after every window close and stayed stopped until
// the next login. Nothing reported the stop: a dead resident and a quiet one look identical.
//
// The issue guessed the cause was #1966's `isInserted:` MenuBarExtra, whose status item macOS can
// remove, and removal takes the process down. It was not. Reproduced on the live Release app on
// 2026-08-04 with the system log open, and the log names the path outright:
//
//   18:24:17.469  Overture[35075]  found no value for key NSTerminateAfterLastWindowClosedDelay
//   18:24:17.472  [AppKit:Menu]    Donating invocation ... 'Command-W', action: performClose:
//   18:24:17.532  [AppKit:Application] terminate:
//   18:24:17.532  [AppKit:Application] Asking app delegate whether applicationShouldTerminate:
//   18:24:17.532  [AppKit:Application] replyToApplicationShouldTerminate:YES
//   18:24:17.537  window <NSStatusBarWindow> ... finishing close
//
// `NSTerminateAfterLastWindowClosedDelay` is the LAST WINDOW CLOSED path. There is no
// "terminating on removal" line anywhere in the capture, and the status bar window closes five
// milliseconds AFTER termination had already begun: the menu bar icon is a casualty of the quit,
// not its cause. So the item being removable was never involved, and reverting #1966 would have
// fixed nothing.
//
// AppKit asks the delegate whether to terminate once the last window closes, and consults the
// answer only when the delegate implements the selector at all. Overture implemented nothing, so
// SwiftUI's own answer stood, and a resident app quit.
@Suite("Closing the window leaves the resident app running (#2088)")
struct ResidentSurvivesWindowCloseTests {

    // Asked through the PROTOCOL, optionally, which is exactly how AppKit reaches it: an optional
    // @objc requirement dispatches through responds(to:), so a delegate that does not implement the
    // method answers nil and AppKit falls back to its own default. That makes this one assertion
    // cover both claims that matter (#887, a guard and its wiring are two claims): that the answer
    // is NO, and that the answer is reachable by the only caller that will ever ask.
    @MainActor
    @Test func theDelegateRefusesToQuitWhenTheLastWindowCloses() {
        let delegate: NSApplicationDelegate = AppDelegate()

        let answer = delegate.applicationShouldTerminateAfterLastWindowClosed?(NSApplication.shared)

        #expect(answer == false,
                "nil means the selector is unimplemented and AppKit uses its own default, which is what quit the app")
    }
}
