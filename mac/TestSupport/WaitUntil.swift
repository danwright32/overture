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
                The usual cause is a fixture that cannot reach the state being awaited, for example a \
                draft body with no greeting, which is held at send (Recipient.isBlockedByGreeting) so the \
                send never happens. Check that first.
                It is not ALWAYS the fixture: under parallel testing this can also be work that was never \
                scheduled, which is what #3277 was (a five second deadline noticed after forty five). \
                This used to say "This is a FAILURE, not a slow machine", which was true serially and \
                false there, in the wording most likely to stop somebody looking further (L11).
                """,
                sourceLocation: sourceLocation)
            return false
        }
        // #3277: SUSPEND, do not spin. This was `await Task.yield()`, which reschedules the waiter
        // immediately, so the loop ran as fast as a core would allow and one waiter burned that core for
        // as long as it waited. Measured 2026-08-30: 12,322 polls in 200 milliseconds, on an idle
        // machine, from a single test.
        //
        // Serially that is invisible, because one spinner on an otherwise idle machine always gets its
        // answer. Under `-parallel-testing-enabled YES -parallel-testing-worker-count 12` there are
        // twelve worker PROCESSES, each with its own cooperative pool sized to the whole machine, and
        // the spinners starve the very work they are waiting for (L241). Two of five consecutive full
        // parallel runs went red, and every failure in both was a test that waits: the clearest was
        // `LoopbackListener.start(timeout: 5)` reporting `failed (45.464 seconds)`, which is not a bind
        // that was refused but a five second deadline that took forty five seconds to be noticed.
        //
        // One millisecond because the cost is what a waiting test can afford to add to its own latency
        // and nothing else: a wait that resolves in 20ms still resolves in about 20ms, and the poll count
        // over the ten second default falls from tens of thousands to ten thousand at worst.
        //
        // `try?` swallows only the cancellation error, and the loop is still bounded by the deadline
        // above rather than by the sleep, so a cancelled task ends at the deadline instead of hanging.
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}
