import Testing
import Foundation

// #1968: a launch that could not open the store used to quit without a word.
//
// `StoreLaunchOutcome.classify` was asked "did this process take the lock?", and the launch answered by
// looking at whether a lock VARIABLE had been set. Only one branch of the launch's if/else chain ever
// set it, so the branch that stops before the lock is even asked for (the one-time store move refusing
// to carry a file that is not Overture's) answered "no", was read as another live copy holding the
// lock, and terminated immediately. Dan saw the window appear and disappear, with no message and no
// crash report.
//
// The rule now runs the other way and is proven in StoreLaunchOutcomeTests: terminating takes an
// AFFIRMATIVE statement that another copy holds the lock, so any route that does not make that
// statement keeps its voice. What no running test can reach is the launch itself: `OvertureApp.swift`
// carries `@main` and is the one file the pure test target cannot compile in, so this guards its shape
// as source text (the same reason FocusedStageWiringGuardTests and MastheadGuardTests do).
@Suite("A launch never quits without saying why (#1968)")
struct LaunchNeverQuitsWithoutSayingWhyGuardTests {
    private var app: String { SourceGuardHelper.source("Overture/App/OvertureApp.swift") }

    // The decisive one: the fact is STATED, never inferred from whether some other variable happens to
    // have been assigned. `lock != nil` reaching this argument is the exact defect, in any spelling.
    @Test func theDuplicateVerdictIsStatedNotInferredFromTheLockVariable() {
        #expect(app.contains("lockHeldByAnotherCopy: lockHeldByAnotherCopy"))
        #expect(!app.contains("lockAcquired:"))
        #expect(!app.contains("lock != nil"))
    }

    // Exactly ONE branch may make the statement, and it is the branch that asked for the lock and was
    // refused. Two of them would mean some other route had started claiming it too.
    @Test func exactlyOneBranchClaimsAnotherCopyHoldsTheLock() {
        let claims = app.components(separatedBy: "lockHeldByAnotherCopy = true").count - 1
        #expect(claims == 1, "expected exactly one branch to state it, found \(claims)")
    }

    // And it starts false, so a launch route added later inherits "say why" rather than "die quietly".
    // This is the whole structural point: the safe outcome is the default, not the remembered one.
    @Test func theDefaultIsTheOutcomeThatKeepsTalking() {
        #expect(app.contains("var lockHeldByAnotherCopy = false"))
    }
}
