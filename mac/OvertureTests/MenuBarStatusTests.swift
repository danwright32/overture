import Testing
import Foundation

// #266 / Phase 2: the menu-bar status line. The only real logic in the menu-bar conversion — what the
// resident menu shows: an error nudge takes priority, else the last reconcile time, else a watching
// idle state. (The MenuBarExtra scene, LSUIElement, and window-on-demand are scene wiring, verified
// by compile + Dan's runtime check.)
@Suite("Menu bar status (#266)")
struct MenuBarStatusTests {
    @Test func anOmniFocusFailureTakesPriority() {
        let line = MenuBarStatus.line(lastReconcileAt: Date(timeIntervalSince1970: 1_000),
                                      now: Date(timeIntervalSince1970: 2_000), omniFocusFailed: true,
                                      hasUnreadLogProblems: false)
        #expect(line == "OmniFocus sync needs attention")
    }

    @Test func noReconcileYetShowsTheWatchingState() {
        let line = MenuBarStatus.line(lastReconcileAt: nil, now: Date(timeIntervalSince1970: 2_000),
                                      omniFocusFailed: false, hasUnreadLogProblems: false)
        #expect(line == "Watching for replies and bookings")
    }

    @Test func aPriorReconcileShowsTheLastCheckedTime() {
        let line = MenuBarStatus.line(lastReconcileAt: Date(timeIntervalSince1970: 1_000),
                                      now: Date(timeIntervalSince1970: 2_000), omniFocusFailed: false,
                                      hasUnreadLogProblems: false)
        #expect(line.hasPrefix("Last checked "))   // exact time string is locale-dependent
        #expect(line.count > "Last checked ".count)
    }

    // #302/#1689: a problem the app NAMED, that Dan has not seen, nudges him to open the logs, so a
    // silently misbehaving overnight agent doesn't go unnoticed. It says "a problem" rather than "an
    // error" because the set of things that raise it includes a paid check that came home short, which
    // is a real thing to look at and is not a failure (L11: claim only what the check measured).
    @Test func unreadLogProblemsNudgeToOpenTheLogs() {
        let line = MenuBarStatus.line(lastReconcileAt: Date(timeIntervalSince1970: 1_000),
                                      now: Date(timeIntervalSince1970: 2_000), omniFocusFailed: false,
                                      hasUnreadLogProblems: true)
        #expect(line == "Agent logged a problem: open agent logs")
    }

    // A known OmniFocus failure is the more specific, more actionable signal, so it still wins over the
    // generic "something was logged as a problem" nudge.
    @Test func anOmniFocusFailureStillWinsOverUnreadLogProblems() {
        let line = MenuBarStatus.line(lastReconcileAt: nil, now: Date(timeIntervalSince1970: 2_000),
                                      omniFocusFailed: true, hasUnreadLogProblems: true)
        #expect(line == "OmniFocus sync needs attention")
    }
}
