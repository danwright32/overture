import Testing
import Foundation

// #3277: `waitUntil` must SUSPEND between polls, not spin.
//
// It was written as `while !condition() { await Task.yield() }` with a deadline bolted on, which is
// correct serially and is what made the parallel switch unstable. `Task.yield()` reschedules the waiter
// immediately, so the loop runs as fast as the CPU allows and one waiter burns a whole core for as long
// as it waits. Serially that is invisible, because a single spinner on an otherwise idle machine always
// gets its answer. Under `-parallel-testing-enabled YES -parallel-testing-worker-count 12` there are
// twelve worker PROCESSES, each with its own cooperative pool sized to the machine, and the spinners
// starve the very work they are waiting for (L241).
//
// Measured 2026-08-30, five consecutive full parallel runs on one tree: two went red, and every failure
// in both was a test that waits. `LoopbackListener.start(timeout: 5)` reported `failed (45.464 seconds)`,
// which is not a bind that was refused but a five second deadline that took forty five seconds to be
// noticed. `ProspectMutationsTests` lost both of its send-marking tests the same way.
//
// What is asserted here is the SHAPE of the wait rather than a duration, because a duration compared
// against a fixed number measures what else the machine is running (L224). A poll count does not: a
// suspending wait can only poll about as often as its sleep allows, however fast or slow the machine,
// while a spinner polls as fast as a core will let it, which is orders of magnitude more. The bound
// below is set far above a correct implementation's real figure and far below a spinner's measured one.
@Suite("waitUntil suspends between polls (#3277)")
struct WaitUntilTests {

    @Test func aWaitThatTimesOutDoesNotSpinTheCPU() async {
        var polls = 0
        await withKnownIssue("the timeout is the point of this case") {
            _ = await waitUntil("something that never happens", timeout: .milliseconds(200)) {
                polls += 1
                return false
            }
        }
        // A 200ms wait polling every millisecond is about 200 times. The measured spinner did tens of
        // thousands in the same window, so anything under this bound cannot be a spin and anything a
        // correct implementation produces is far under it.
        #expect(polls < 2_000,
                "waitUntil polled \(polls) times in 200ms, which is a busy spin rather than a suspending wait")
        // And it must poll at ALL: a wait that never re-checks would satisfy the bound above by doing
        // nothing, which is the same defect pointing the other way (L98).
        #expect(polls > 1, "waitUntil polled \(polls) times, so it is not re-checking the condition")
    }

    @Test func aConditionThatIsAlreadyTrueReturnsWithoutWaiting() async {
        let answered = await waitUntil("a condition that already holds") { true }
        #expect(answered)
    }

    // The condition flips on its THIRD reading, so this asserts what the loop is for (it re-checks, and
    // it returns as soon as the answer changes) without asserting anything about the scheduler.
    //
    // Written first with a background task that flipped a flag after 50 milliseconds, and that version
    // failed in all THREE parallel confirmation runs, never in a serial one. It was measuring the
    // machine, not the wait (L290): under twelve worker processes an unstructured task's 50 millisecond
    // sleep did not complete inside a ten second deadline. That is a real finding about the worker count
    // and it belongs in #3277's own measurements, not inside a unit test for a helper.
    @Test func aConditionThatBecomesTrueIsNoticed() async {
        var readings = 0
        let answered = await waitUntil("a condition that becomes true on its third reading") {
            readings += 1
            return readings >= 3
        }
        #expect(answered, "the wait gave up on a condition that did become true")
        #expect(readings == 3, "the wait read the condition \(readings) times, so it did not stop at the answer")
    }

    @Test func aWaitThatTimesOutReportsFailureRatherThanHanging() async {
        var answered = true
        await withKnownIssue("the timeout is the point of this case") {
            answered = await waitUntil("something that never happens", timeout: .milliseconds(50)) { false }
        }
        #expect(answered == false, "a timed-out wait must report false, not true")
    }

    // The CLASS, not the instance. `waitUntil` was the one unbounded spin in the tree, and the reason it
    // cost two runs in five is that it is a SHARED helper: one busy loop reached by many tests. Nothing
    // stopped the next one being written, so this is that guard.
    //
    // It flags a `Task.yield()` whose nearest enclosing loop is a `while`, which is the unbounded shape.
    // A BOUNDED `for _ in 0..<8 { await Task.yield() }` is left alone, and that is not a loophole: it
    // runs a fixed number of times and returns the thread, which is what `SharedStateTestLockTests` uses
    // to let a competing task reach the lock. An unbounded one never returns the thread until its
    // condition flips, which is the defect.
    //
    // Judged by scanning BACKWARD to the nearest loop keyword rather than by a fixed window of lines: a
    // window is answered by whatever happens to be inside it, and a comment added above the loop moves
    // the code out of it (L518).
    // #3266: a timeout may be declared only on EVIDENCE, and the evidence is having actually read the
    // condition.
    //
    // Measured 2026-08-30 on the first complete one-worker parallel run of the whole suite (8,633 tests,
    // 140.0s): the only failure in it was `aConditionThatBecomesTrueIsNoticed`, and the result bundle
    // gives the reason as `(readings -> 2) == 3`. The wait read its condition TWICE inside a ten second
    // deadline. Its condition becomes true on the third reading and nothing else is involved in it, so
    // nothing was slow except the waiter itself: one `Task.sleep(for: .milliseconds(1))` resumed more
    // than ten seconds late, because Swift Testing runs the tests of one process concurrently on a
    // cooperative pool that this suite's thousands of synchronous source scans and SQLite clones keep
    // busy. #3277 stopped the waiter BURNING a pool thread; it did not stop the waiter being starved of
    // one.
    //
    // The claim a timeout makes is "the condition stayed false". Read twice, that claim is not
    // measured, and an unmeasured claim must not be reported as a measured one (L98). So the deadline
    // is necessary and no longer sufficient: the wait also has to have LOOKED, and `minimumPolls` is
    // how many times. That keeps the bound the deadline exists for (L110), because the extra waiting is
    // at most `minimumPolls` sleeps and not one more.
    //
    // Both seams are injected rather than driven by real time, so neither case here waits for anything
    // or measures what else the machine is running (L290, L224). The starved sleeper advances the fake
    // clock by 11 seconds per poll, which is the shape of the real failure and past the 10 second
    // deadline in one hop.
    @Test func aStarvedWaitIsNotReadAsAConditionThatNeverBecameTrue() async {
        var readings = 0
        var clock = ContinuousClock.now
        let answered = await waitUntil("a condition that becomes true on its third reading",
                                       timeout: .seconds(10),
                                       now: { clock },
                                       sleep: { clock = clock.advanced(by: .seconds(11)) }) {
            readings += 1
            return readings >= 3
        }
        #expect(answered, "the wait gave up on a condition that did become true, having been starved")
        #expect(readings == 3, "the wait read the condition \(readings) times, so the deadline was spent unscheduled")
    }

    // The other half, and it is what stops the rule above becoming a hang: a condition that never
    // becomes true is still given up on, and the extra waiting is BOUNDED by the poll count rather than
    // being extended for as long as the starvation lasts. Without this the fix for the case above is a
    // wait that can never fail, which is the defect `waitUntil` was built to remove (L110).
    //
    // `minimumPolls` is passed here rather than left at its default, and the expected count is the value
    // passed. That is what makes this a test of the parameter rather than of the number 3: with the
    // default on both sides, an implementation that ignored the argument entirely and hard-coded its own
    // bound would pass (L70).
    @Test func aStarvedWaitStillGivesUpRatherThanWaitingForever() async {
        var polls = 0
        var clock = ContinuousClock.now
        var answered = true
        await withKnownIssue("the timeout is the point of this case") {
            answered = await waitUntil("something that never happens",
                                       timeout: .seconds(10),
                                       minimumPolls: 2,
                                       now: { clock },
                                       sleep: { clock = clock.advanced(by: .seconds(11)) }) {
                polls += 1
                return false
            }
        }
        #expect(answered == false, "a timed-out wait must report false, not true")
        #expect(polls == 2, "a starved wait read the condition \(polls) times, so its extra waiting is not bounded")
    }

    @Test func noTestSpinsOnAnUnboundedTaskYield() throws {
        let roots = ["OvertureTests", "OvertureHostedTests", "TestSupport"]
        var filesRead = 0
        var offenders: [String] = []

        for root in roots {
            let files = AppSourceWalk.files(under: RepoRoot.mac.appendingPathComponent(root), floor: 1)
            filesRead += files.count
            for file in files where file.name != "WaitUntilTests.swift" {
                let lines = file.text.components(separatedBy: "\n")
                for (index, line) in lines.enumerated() where line.contains("Task.yield()") {
                    // A line that only TALKS about it is not one that runs it.
                    let code = line.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0]
                    guard code.contains("Task.yield()") else { continue }
                    var enclosing = "none"
                    var back = index
                    while back > 0 {
                        back -= 1
                        let candidate = lines[back].trimmingCharacters(in: .whitespaces)
                        if candidate.hasPrefix("//") { continue }
                        if candidate.hasPrefix("while ") || candidate.contains(" while ") { enclosing = "while"; break }
                        if candidate.hasPrefix("for ") || candidate.contains(" for ") { enclosing = "for"; break }
                        if candidate.hasPrefix("func ") || candidate.hasPrefix("@Test") { break }
                    }
                    if enclosing == "while" {
                        offenders.append("\(file.name):\(index + 1)")
                    }
                }
            }
        }

        // Zero files read is unmeasured, never clean: a wrong root empties the corpus and this guard
        // reports a tree with no spins in it while checking nothing (L98).
        #expect(filesRead > 200, "walked \(filesRead) files, which is a broken path rather than a small test target")
        #expect(offenders.isEmpty, """
            These wait by SPINNING on Task.yield() inside a while loop, which holds a pool thread for as \
            long as the wait lasts and starves the work being waited for under parallel testing (#3277, \
            L241): \(offenders.joined(separator: ", ")). Use waitUntil, which suspends between polls and \
            carries a deadline.
            """)
    }
}
