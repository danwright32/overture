import Testing
import Foundation
@testable import Overture

// #266 / Phase 2: the menu-bar status line. The only real logic in the menu-bar conversion — what the
// resident menu shows: an error nudge takes priority, else the last reconcile time, else a watching
// idle state. (The MenuBarExtra scene, LSUIElement, and window-on-demand are scene wiring, verified
// by compile + Dan's runtime check.)
@Suite("Menu bar status (#266)")
struct MenuBarStatusTests {
    @Test func anOmniFocusFailureTakesPriority() {
        let line = MenuBarStatus.line(lastReconcileAt: Date(timeIntervalSince1970: 1_000),
                                      now: Date(timeIntervalSince1970: 2_000), omniFocusFailed: true,
                                      hasUnreadLogErrors: false)
        #expect(line == "OmniFocus sync needs attention")
    }

    @Test func noReconcileYetShowsTheWatchingState() {
        let line = MenuBarStatus.line(lastReconcileAt: nil, now: Date(timeIntervalSince1970: 2_000),
                                      omniFocusFailed: false, hasUnreadLogErrors: false)
        #expect(line == "Watching for replies and bookings")
    }

    @Test func aPriorReconcileShowsTheLastCheckedTime() {
        let line = MenuBarStatus.line(lastReconcileAt: Date(timeIntervalSince1970: 1_000),
                                      now: Date(timeIntervalSince1970: 2_000), omniFocusFailed: false,
                                      hasUnreadLogErrors: false)
        #expect(line.hasPrefix("Last checked "))   // exact time string is locale-dependent
        #expect(line.count > "Last checked ".count)
    }

    // #302: unseen agent stderr nudges Dan to open the logs, so a silently misbehaving overnight agent
    // doesn't go unnoticed.
    @Test func unreadLogErrorsNudgeToOpenTheLogs() {
        let line = MenuBarStatus.line(lastReconcileAt: Date(timeIntervalSince1970: 1_000),
                                      now: Date(timeIntervalSince1970: 2_000), omniFocusFailed: false,
                                      hasUnreadLogErrors: true)
        #expect(line == "Agent logged an error: open agent logs")
    }

    // A known OmniFocus failure is the more specific, more actionable signal, so it still wins over the
    // generic "something hit stderr" nudge.
    @Test func anOmniFocusFailureStillWinsOverUnreadLogErrors() {
        let line = MenuBarStatus.line(lastReconcileAt: nil, now: Date(timeIntervalSince1970: 2_000),
                                      omniFocusFailed: true, hasUnreadLogErrors: true)
        #expect(line == "OmniFocus sync needs attention")
    }
}
