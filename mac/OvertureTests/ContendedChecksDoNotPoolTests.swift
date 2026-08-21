import Testing
import Foundation

// #2762 (phase 6 of #2620): a check that shared the machine is not evidence about one that has it to
// itself.
//
// #1616 taught the selection bar to learn its wait from the checks that actually ran. It pools the last
// ten and takes over the pre-spend estimate at three samples, which was right while exactly one run could
// ever be alive. #2620 is removing that, so the first three checks run beside a Prep run would quietly
// retrain the figure Dan reads BEFORE deciding to spend, and it would read as evidence rather than as a
// different measurement (L37).
//
// So a sample now carries whether it was CONTENDED, and the two classes never pool. What "contended"
// means here is narrow and deliberate: another RUN SLOT was alive during this run. It is not "the machine
// was busy". A scout extract or a reply classify can also be going, and #2762's measurement session
// counts those directly, because a stored flag whose meaning drifted between the runs that carry it and
// the runs that do not would be worse than no flag (L118).
@Suite("Contended check pace (#2762)")
struct ContendedChecksDoNotPoolTests {

    private func runs(_ items: [(lookups: Int, streams: Int, seconds: Double, contended: Bool)])
        -> ProbeDurationHistory {
        ProbeDurationHistory(runs: items.map {
            ProbeDurationHistory.Run(lookups: $0.lookups, streams: $0.streams, seconds: $0.seconds,
                                     contended: $0.contended)
        })
    }

    // MARK: - The two classes never pool

    // The defect this issue names, stated as a test: three contended checks must not move the figure the
    // bar quotes for a check that will have the machine to itself.
    @Test func aContendedSampleIsNeverPooledWithASoloOne() {
        let history = runs([
            (10, 10, 300, false), (10, 10, 300, false), (10, 10, 300, false),
            (10, 10, 500, true), (10, 10, 500, true), (10, 10, 500, true),
        ])
        #expect(history.learnedSecondsPerRound(contended: false) == 300)
        #expect(history.learnedSecondsPerRound(contended: true) == 500)
    }

    // Each class needs its own handful. Two contended samples beside three solo ones is still no evidence
    // about a contended run, and answering with the solo pace would be pooling across by another route.
    @Test func eachClassNeedsItsOwnHandfulBeforeAnythingIsLearned() {
        let history = runs([
            (10, 10, 300, false), (10, 10, 300, false), (10, 10, 300, false),
            (10, 10, 500, true), (10, 10, 500, true),
        ])
        #expect(history.learnedSecondsPerRound(contended: true) == nil)
        #expect(history.learnedSecondsPerRound(contended: false) == 300)
    }

    // And a class with no evidence quotes the hand-set constant, which is the state that already ships and
    // the one that has to stay honest: no history for the machine you are about to run on, no claim.
    @Test func aClassWithNoEvidenceQuotesTheConstant() {
        let soloOnly = runs([(10, 10, 240, false), (10, 10, 240, false), (10, 10, 240, false)])
        #expect(ProbeSelection.secondsPerRound(learnedFrom: soloOnly, contended: true)
                == ProbeSelection.fallbackSecondsPerRound)
        #expect(ProbeSelection.secondsPerRound(learnedFrom: soloOnly, contended: false) == 240)
    }

    // The ceiling `isComparable` already applies is per ROUND and it does not move for a contended run, so
    // a co-run round slower than `RunTimeouts.reachabilityProbe` is refused as "a run that went wrong"
    // rather than stored as the contended pace. That is the right rule and the wrong constant: the limit
    // was derived from a SOLO measurement, so the contended class can be structurally unable to fill.
    //
    // Pinned here because it is the coupling #2762's measurement has to settle, and it is invisible from
    // either side alone: nothing fails, the history simply stays empty and the bar goes on quoting the
    // constant while real evidence is thrown away every run (L98).
    @Test func aContendedRoundSlowerThanTheSoloCeilingIsRefusedRatherThanLearned() {
        let overCeiling = RunTimeouts.reachabilityProbe + 1
        let history = runs([
            (10, 10, overCeiling, true), (10, 10, overCeiling, true), (10, 10, overCeiling, true),
        ])
        #expect(history.learnedSecondsPerRound(contended: true) == nil)
        #expect(history.runs.count == 3)   // stored by the test's own initializer, refused by the pooling
    }

    // MARK: - Neither class can starve the other

    // The window is "the last ten" so the pace tracks recent behaviour, and once there are two classes
    // that has to mean the last ten OF EACH. Capped across both, a stretch of co-runs would evict every
    // solo sample, and the next check with the machine to itself would quote the hand-set constant with a
    // full history sitting beside it, which is the exact failure `recording` already refuses for
    // uncomparable runs.
    @Test func eachClassKeepsItsOwnLastTen() {
        var history = ProbeDurationHistory()
        for i in 1...12 {
            history = history.recording(lookups: 10, streams: 10, seconds: 300 + Double(i), contended: true)
        }
        for i in 1...12 {
            history = history.recording(lookups: 10, streams: 10, seconds: 200 + Double(i), contended: false)
        }
        #expect(history.runs.filter { $0.contended }.count == ProbeDurationHistory.maxEntries)
        #expect(history.runs.filter { !$0.contended }.count == ProbeDurationHistory.maxEntries)
        // And it is the LAST ten of each that survived, not the first.
        #expect(history.runs.filter { $0.contended }.first?.seconds == 303)
        #expect(history.runs.filter { !$0.contended }.first?.seconds == 203)
    }

    // MARK: - What the runner reported

    // The flag reaches the history from the run's own results file, beside the wall clock it qualifies.
    // One observer for both facts about one span: the runner is the only thing alive for the whole of it,
    // and two observers would disagree exactly when it matters (L70).
    @Test func aRecordedRunCostCarriesWhetherItWasContended() {
        let contended = """
        {"runCost":{"recorded":true,"usd":1.5,"durationMs":300000,"streams":10,"contended":true}}
        """
        #expect(RecordedRunCost.complete(from: Data(contended.utf8))?.contended == true)

        let solo = """
        {"runCost":{"recorded":true,"usd":1.5,"durationMs":300000,"streams":10,"contended":false}}
        """
        #expect(RecordedRunCost.complete(from: Data(solo.utf8))?.contended == false)
    }

    // A runner that said nothing reports UNKNOWN, never solo. This is a real state rather than a
    // defensive one: the runner script is resolved out of the git checkout, and `update-overture.sh`
    // fast-forwards the checkout before the rebuild, so a new app meets a script that predates the flag
    // for a couple of minutes on every update, and permanently for anyone who only pulls.
    @Test func aRunnerThatSaidNothingReportsUnknownRatherThanSolo() {
        let silent = """
        {"runCost":{"recorded":true,"usd":1.5,"durationMs":300000,"streams":10}}
        """
        let cost = RecordedRunCost.complete(from: Data(silent.utf8))
        #expect(cost != nil)
        #expect(cost?.contended == nil)
    }

    // And an unknown sample is not stored at all. It cannot be filed as solo without mislabelling exactly
    // the co-run this issue exists to measure, and it cannot be filed as contended either, so it teaches
    // neither class and costs one sample inside a two minute update window.
    @Test func aSampleWhoseContentionIsUnknownIsNotRecorded() {
        let unknown = RecordedRunCost(seconds: 300, streams: 10, contended: nil, kind: .reachabilityCheck)
        #expect(ProbeRunPaceRecording.sample(lookups: 10, cost: unknown, cancelled: false) == nil)

        let known = RecordedRunCost(seconds: 300, streams: 10, contended: true, kind: .reachabilityCheck)
        let sample = ProbeRunPaceRecording.sample(lookups: 10, cost: known, cancelled: false)
        #expect(sample?.contended == true)
    }

    // MARK: - The history already on disk

    // Every row written before this change ran under the prep/check exclusion, which #2760 left in force
    // and #2765 is what lifts, so no other slot could have been beside it. That makes reading a
    // flagless row as SOLO a fact about the code that wrote it rather than an assumption about the data,
    // and it is the one place the default is allowed to live (L90 is why it is written down here).
    @Test func aRowWrittenBeforeTheFlagExistedReadsAsSolo() throws {
        let legacy = """
        {"version":1,"runs":[
          {"lookups":10,"streams":10,"seconds":300},
          {"lookups":10,"streams":10,"seconds":300},
          {"lookups":10,"streams":10,"seconds":300}
        ]}
        """
        let history = try JSONDecoder().decode(ProbeDurationHistory.self, from: Data(legacy.utf8))
        #expect(history.runs.allSatisfy { $0.contended == false })
        #expect(history.learnedSecondsPerRound(contended: false) == 300)
        #expect(history.learnedSecondsPerRound(contended: true) == nil)
    }

    // Every row this writes carries the key, which is what makes the rule above safe: a flagless row can
    // only ever be one written before the flag existed, never one this version chose not to stamp.
    @Test func everyRowThisVersionWritesCarriesTheFlag() throws {
        let history = runs([(10, 10, 300, false), (10, 10, 500, true)])
        let text = String(decoding: try JSONEncoder().encode(history), as: UTF8.self)
        #expect(text.contains("\"contended\":false"))
        #expect(text.contains("\"contended\":true"))
    }

    // MARK: - The reader

    // The field has a reader in the same change, and it is the live entry point the three surfaces that
    // quote a wait already call, so no surface can consult one class while another consults the other
    // (L46). The reader asks the question the run is about to answer: is the other slot alive right now.
    @Test func theLiveEstimateAsksWhetherTheOtherSlotIsAlive() {
        let text = SourceGuardHelper.source("Overture/Domain/ProbeSelection.swift")
        #expect(text.contains("PrepQueueService.isRunning(slot: .prep"))
        #expect(text.contains("contended:"))
    }
}
