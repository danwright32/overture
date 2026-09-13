import Testing
import Foundation

// #3842: the rule that separates "this could not be measured" from "this failed".
//
// Every outcome is PRODUCED here rather than waited for, because no test can set the machine state the
// live reading depends on: a suite that could only observe whatever this Mac happens to be doing would be
// green for a reason nobody chose (L151, L411).
@Suite("A locked screen is unmeasured, not a failure (#3842)")
struct ALockedScreenIsUnmeasuredTests {

    @Test func alockedSessionReadsAsLocked() {
        #expect(ScreenSession.isLocked(in: ["CGSSessionScreenIsLocked": NSNumber(value: 1)]))
    }

    @Test func anunlockedSessionReadsAsUnlocked() {
        #expect(!ScreenSession.isLocked(in: ["CGSSessionScreenIsLocked": NSNumber(value: 0)]))
    }

    // A session dictionary that carries no lock key at all. This reader CANNOT SAY, and it answers
    // "not locked" so the tests still run and still fail loudly, which is the recoverable direction: a
    // silently skipped test is the failure this whole mechanism exists to prevent (L93).
    @Test func asessionWithNoLockKeyRunsTheTests() {
        #expect(!ScreenSession.isLocked(in: ["kCGSSessionUserNameKey": "someone" as NSString]))
    }

    @Test func nosessionAtAllRunsTheTests() {
        #expect(!ScreenSession.isLocked(in: nil))
    }

    // The MARKER the runner reads, asserted on its spelling, because the reader is a shell script and
    // cannot import this file. Two copies of one string is how they drift (L41, L70).
    @Test func themarkerIsTheOneTheRunnerLooksFor() throws {
        let runner = try String(contentsOf: RepoRoot.mac.appendingPathComponent("scripts/run-tests-locked.sh"),
                                encoding: .utf8)
        // Bound to a Bool first: `#expect` renders its operands and this one is a 1,500 line shell
        // script, which would bury the message saying what went wrong (L445).
        let looksForTheMarker = runner.contains("screen-locked-unmeasured")
        #expect(looksForTheMarker,
                Comment(rawValue: "the runner does not look for the marker these tests print, so a run "
                        + "that could not drive a window would say nothing at all about it, which is the "
                        + "silent skip #3842 exists to prevent (L98)."))
    }
}
