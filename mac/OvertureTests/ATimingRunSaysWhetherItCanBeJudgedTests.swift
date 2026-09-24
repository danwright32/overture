import Testing
import Foundation

// #3918: a timing run says whether it is steady enough to judge a ceiling against.
//
// THE MEASUREMENT BEHIND IT. `QueueRenderPassLiveStoreCostTests` was run twice on 2026-09-23, ten
// minutes apart, against the same store and the same code. Quiet: the prospect fetch 205.5 ms, five
// repeats spanning 203.6 to 212.5, which is 4% of the median. Loaded, at a one minute load average of
// 51.6: 694.7 ms, repeats spanning 353.1 to 902.3, which is 79%. The loaded run's per row figure was
// 0.5207 ms against a shipped ceiling of 0.50, so the ratchet FAILED on unchanged code.
//
// A red a busy machine caused is indistinguishable from a red the code caused, and the second time it
// happens somebody starts re-running the suite until it is quiet, which is how a guard becomes
// decoration (L411, L224).
@Suite("A timing run says whether it can be judged (#3918)")
struct ATimingRunSaysWhetherItCanBeJudgedTests {

    // MARK: - The rule, with every outcome PRODUCED rather than reasoned about (L151)

    // The quiet reading, as measured. It must be judgeable, or the ratchet never runs at all.
    @Test func theQuietReadingActuallyMeasuredIsSteady() {
        #expect(TimingReadability.verdict(low: 203.6, high: 212.5, median: 205.5) == .steady)
    }

    // The loaded reading, as measured. It must NOT be judged, or it fails the code for the machine.
    @Test func theLoadedReadingActuallyMeasuredIsRefused() {
        let verdict = TimingReadability.verdict(low: 353.1, high: 902.3, median: 694.7)
        guard case .unmeasurable(let fraction) = verdict else {
            Issue.record(Comment(rawValue:
                "the 79% spread measured at load 51.6 was judged steady, so the ratchet would still "
                + "fail the code for the machine"))
            return
        }
        #expect(fraction > 0.7, Comment(rawValue:
            "the spread came out as \(fraction), which does not match the 79% that was measured"))
    }

    // THE BOUNDARY, from both sides, so the threshold is a line something is actually on rather than a
    // number nothing is ever compared against.
    @Test func aSpreadExactlyAtTheThresholdIsStillSteady() {
        #expect(TimingReadability.verdict(low: 75, high: 100, median: 100) == .steady)
    }

    @Test func aSpreadJustPastTheThresholdIsRefused() {
        #expect(TimingReadability.verdict(low: 74, high: 100, median: 100)
                == .unmeasurable(spreadFraction: 0.26))
    }

    // A run with nothing to read must say so rather than claiming steadiness, which is what a zero
    // median or a reversed pair is (L98).
    @Test func aRunWithNothingToReadSaysSoRatherThanPassing() {
        #expect(TimingReadability.verdict(low: 0, high: 0, median: 0) == .noReading)
        #expect(TimingReadability.verdict(low: 100, high: 50, median: 75) == .noReading)
    }

    // MARK: - Folding several arms, because one bouncing arm spoils every comparison in the run

    @Test func aRunIsJudgedByItsLeastSteadyArm() {
        let verdicts: [TimingReadability.Verdict] = [
            .steady, .unmeasurable(spreadFraction: 0.4), .unmeasurable(spreadFraction: 0.9), .steady,
        ]
        #expect(TimingReadability.worst(of: verdicts) == .unmeasurable(spreadFraction: 0.9))
    }

    @Test func aRunWhoseArmsAreAllSteadyIsSteady() {
        #expect(TimingReadability.worst(of: [.steady, .steady]) == .steady)
    }

    // An arm that could not be read at all outranks an unsteady one: it is a stronger statement about
    // the run than a wide spread is, and folding it into "unsteady" would invent a spread nobody read.
    @Test func anArmWithNoReadingOutranksAnUnsteadyOne() {
        #expect(TimingReadability.worst(of: [.unmeasurable(spreadFraction: 0.9), .noReading])
                == .noReading)
    }

    @Test func noArmsAtAllIsNoReadingRatherThanSteady() {
        #expect(TimingReadability.worst(of: []) == .noReading)
    }

    // MARK: - And the ceilings really are gated on it (L3: built is not wired)

    // Every test above exercises the rule in isolation, so all of them would pass while the cost suite
    // went on asserting its ceilings unconditionally. This is the half that says the rule is IN the path.
    @Test func theCostSuiteGatesItsCeilingsOnTheVerdict() {
        let source = SourceGuardHelper.source("OvertureTests/QueueRenderPassLiveStoreCostTests.swift")
        #expect(!source.isEmpty, "the cost suite could not be read, so this guard checked nothing")
        #expect(SourceGuardHelper.containsCode("TimingReadability.worst(of:", in: source),
                Comment(rawValue:
            "the live store cost suite does not fold its arms' steadiness, so its ceilings are still "
            + "asserted on a run that may have been measuring the machine (#3918)"))
        #expect(SourceGuardHelper.containsCode("case .steady:", in: source), Comment(rawValue:
            "the cost suite does not branch on the steady verdict, so whatever it computes about "
            + "steadiness it is not acting on"))
    }
}
