import Testing
import Foundation

// #2576: the one way this suite waits for something to happen.
//
// It exists because the obvious spelling, `while !condition { await Task.yield() }`, CANNOT FAIL. It can
// only hang, and a hang is worse than a failure in every way that matters here: it takes the whole suite
// with it, it holds the machine-wide xcodebuild lock so nothing else can run either, and from outside it
// is indistinguishable from a slow machine, so the person watching waits instead of looking.
//
// Measured twice on 2026-08-12, both from the same cause. #2545 made a draft body with no greeting
// unsendable; two test fixtures still had one; the send never happened, so `sender.callCount` stayed at
// zero forever. The first run span for over an hour writing 21MB of repeated CoreData errors while a
// second run sat blocked behind it for 50 minutes, and three status reports in a row said "waiting on the
// suite" when the work had been dead the whole time. The second cost another 40 minutes the same way.
//
// The deadline turns both of those into a ten second failure that NAMES what it was waiting for, which is
// the difference between a fixture bug you fix in a minute and an afternoon of believing the machine is
// busy (L110).
//
// `ContinuousClock` on purpose: it is monotonic, so it cannot be dragged around by a wall-clock change
// mid-run, and unlike `ProcessInfo.systemUptime` it does not stop counting when the lid closes (L82).
// `@MainActor` rather than free-floating, and that is a Swift 6 requirement rather than a style choice:
// every condition passed in reads mutable state the test owns (a captured array, a fake sender's call
// count), which is not Sendable, so a non-isolated async helper would be sending it across an isolation
// boundary. All three suites that wait are already `@MainActor`, so matching them is what lets the
// closure stay an ordinary one instead of forcing every call site to wrap its state in a box.
@MainActor
@discardableResult
func waitUntil(_ whatIsAwaited: String,
               timeout: Duration = .seconds(10),
               sourceLocation: SourceLocation = #_sourceLocation,
               _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline {
            Issue.record("""
                Timed out after \(timeout) waiting for: \(whatIsAwaited).
                This is a FAILURE, not a slow machine. The usual cause is a fixture that cannot reach the \
                state being awaited, for example a draft body with no greeting, which is held at send \
                (Recipient.isBlockedByGreeting) so the send never happens.
                """,
                sourceLocation: sourceLocation)
            return false
        }
        await Task.yield()
    }
    return true
}
