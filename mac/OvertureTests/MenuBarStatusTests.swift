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
    // #2091: THE defect this line had. With no date on it, "Last checked 9:14 PM" reads exactly the
    // same three days into an outage as it does thirty seconds after a healthy tick, so the menu bar
    // reported a dead watcher as a working one. A live silence now replaces it.
    @Test func aStoppedWatchReplacesTheCheerfulLastCheckedTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stale = MenuBarStatus.line(lastReconcileAt: now.addingTimeInterval(-3 * 86_400), now: now,
                                       omniFocusFailed: false, hasUnreadLogProblems: false,
                                       watchReport: .ongoing(awakeSeconds: 3 * 86_400))
        #expect(stale == "Overture has not checked for replies or bookings in 3d")
        #expect(!stale.hasPrefix("Last checked "))
    }

    // It outranks the other nudges: they are about work this app is supposed to be doing, and a stopped
    // watcher means it is doing none of it.
    @Test func aStoppedWatchOutranksTheOtherNudges() {
        let line = MenuBarStatus.line(lastReconcileAt: nil, now: Date(timeIntervalSince1970: 2_000),
                                      omniFocusFailed: true, hasUnreadLogProblems: true,
                                      watchReport: .ongoing(awakeSeconds: 2 * 3_600))
        #expect(line == "Overture has not checked for replies or bookings in 2h")
    }

    // A silence that has already ENDED is history, and the queue masthead is where it is read. The menu
    // bar goes back to its ordinary line rather than repeating it in a second place.
    @Test func aRecoveredSilenceDoesNotHoldTheMenuBarLine() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let line = MenuBarStatus.line(lastReconcileAt: now, now: now, omniFocusFailed: false,
                                      hasUnreadLogProblems: false,
                                      watchReport: .recovered(cause: .notRunning, seconds: 3 * 86_400,
                                                              endedAt: now.addingTimeInterval(-600)))
        #expect(line.hasPrefix("Last checked "))
    }

    @Test func anOmniFocusFailureStillWinsOverUnreadLogProblems() {
        let line = MenuBarStatus.line(lastReconcileAt: nil, now: Date(timeIntervalSince1970: 2_000),
                                      omniFocusFailed: true, hasUnreadLogProblems: true)
        #expect(line == "OmniFocus sync needs attention")
    }

    // #1688: the item promises the logs only when there are logs to open. When there are none it says
    // what the click will really do, at the moment Dan is choosing whether to click, rather than
    // opening a Finder window and leaving him to work out that this is not what he asked for.
    @Test func theLogsItemPromisesTheLogsOnlyWhenThereAreSome() {
        #expect(MenuBarStatus.logsMenuTitle(hasLogToOpen: true) == "Open agent logs")
    }

    @Test func theLogsItemSaysSoWhenNothingHasBeenLogged() {
        #expect(MenuBarStatus.logsMenuTitle(hasLogToOpen: false)
                == "Open logs folder (nothing logged yet)")
    }
}
