import Testing
import Foundation

// #1616: the wait the selection bar promises, learned from checks that actually ran.
//
// The bar used to multiply the number of rounds by one hand-set constant, measured once from three shows
// run ONE AFTER ANOTHER. Every check since has recorded its real wall clock in `runCost.durationMs`, so
// the app was sitting on better evidence than the guess it used.
//
// What these tests pin is the honesty of the learning, not the arithmetic alone: nothing is learned from
// fewer than a handful of runs, a run whose recorded cost cannot be read teaches nothing rather than
// teaching zero (L50), and a run that did not run the way the next one will is never pooled with runs
// that did.
@Suite("Learned reachability wait (#1616)")
struct ProbeDurationHistoryTests {

    private func history(_ runs: [(lookups: Int, streams: Int, seconds: Double)]) -> ProbeDurationHistory {
        ProbeDurationHistory(runs: runs.map {
            ProbeDurationHistory.Run(lookups: $0.lookups, streams: $0.streams, seconds: $0.seconds, contended: false)
        })
    }

    // MARK: - How many runs before anything is learned

    // Zero, one and two are all the same answer, and it is the answer the app shipped with. A single
    // check says nothing about the next one: the three lookups inside the one recorded check on this Mac
    // took 146s, 390s and 150s, a spread of nearly three to one.
    @Test func nothingIsLearnedUntilAHandfulOfChecksExist() {
        #expect(ProbeDurationHistory().learnedSecondsPerRound(contended: false) == nil)                       // fresh install
        #expect(history([(3, 3, 300)]).learnedSecondsPerRound(contended: false) == nil)                       // one
        #expect(history([(3, 3, 300), (3, 3, 300)]).learnedSecondsPerRound(contended: false) == nil)          // two
        #expect(history([(3, 3, 300), (3, 3, 300), (3, 3, 300)]).learnedSecondsPerRound(contended: false) == 300)
    }

    // The whole point: what the bar quotes moves once there is evidence, and until then it is exactly
    // what it was.
    @Test func theEstimateFallsBackToTheConstantUntilThereIsEnoughHistory() {
        #expect(ProbeSelection.secondsPerRound(learnedFrom: ProbeDurationHistory(), contended: false)
                == ProbeSelection.fallbackSecondsPerRound)
        #expect(ProbeSelection.secondsPerRound(learnedFrom: history([(3, 3, 300), (3, 3, 300)]), contended: false)
                == ProbeSelection.fallbackSecondsPerRound)
        #expect(ProbeSelection.secondsPerRound(learnedFrom: history([(4, 4, 240), (4, 4, 240), (4, 4, 240)]), contended: false)
                == 240)
    }

    // MARK: - Sequential and parallel are not the same measurement

    // A round is one wave of concurrent lookups and its wall clock is its SLOWEST member, so a run whose
    // lookups went through one at a time is measuring a different quantity entirely. Pooled together the
    // two predict neither, so a run that did not fan out is never pooled.
    @Test func aRunThatDidNotFanOutIsNeverPooled() {
        // Three lookups down one stream: the old sequential shape, 471 seconds for three shows.
        #expect(history([(3, 1, 471), (3, 1, 471), (3, 1, 471)]).learnedSecondsPerRound(contended: false) == nil)
        // And one lookup on its own is not a round of ten competing for the machine either.
        #expect(history([(1, 1, 157), (1, 1, 157), (1, 1, 157)]).learnedSecondsPerRound(contended: false) == nil)
    }

    // A sequential sample sitting beside real ones must not drag the pooled figure toward a number that
    // describes neither shape.
    @Test func aSequentialSampleDoesNotDragTheLearnedPace() {
        let mixed = history([(3, 3, 300), (3, 3, 300), (3, 3, 300), (3, 1, 471)])
        #expect(mixed.learnedSecondsPerRound(contended: false) == 300)
    }

    // MARK: - The pace itself

    // Rounds, never lookups: the runner splits the work-list into up to ten concurrent chunks and each
    // chunk works through its slice in order, so a 25-lookup run over 10 streams is three rounds deep.
    @Test func roundsCountTheWavesNotTheLookups() {
        #expect(ProbeDurationHistory.rounds(lookups: 3, streams: 3) == 1)
        #expect(ProbeDurationHistory.rounds(lookups: 10, streams: 10) == 1)
        #expect(ProbeDurationHistory.rounds(lookups: 25, streams: 10) == 3)
        #expect(ProbeDurationHistory.rounds(lookups: 77, streams: 10) == 8)
    }

    // Pooled (total seconds over total rounds), not the mean of per-run paces, so a long multi-round run
    // weighs more than a single-round one. Same rule the Reading-calendars pace already uses.
    @Test func thePaceIsPooledAcrossTheStoredChecks() {
        // 300s over 1 round, 600s over 2 rounds, 900s over 3 rounds: 1800 seconds over 6 rounds.
        let h = history([(5, 5, 300), (20, 10, 600), (25, 10, 900)])
        #expect(h.learnedSecondsPerRound(contended: false) == 300)
    }

    @Test func theLearnedPaceReachesTheQuotedWait() {
        let learned = ProbeSelection.secondsPerRound(learnedFrom: history([(4, 4, 240), (4, 4, 240), (4, 4, 240)]), contended: false)
        #expect(ProbeSelection.estimatedSeconds(forLookups: 4, secondsPerRound: learned) == 240)
        #expect(ProbeSelection.estimatedSeconds(forLookups: 25, secondsPerRound: learned) == 720)
        #expect(ProbeSelectionCopy.durationLabel(
            ProbeSelection.estimatedSeconds(forLookups: 4, secondsPerRound: learned)) == "about 4 minutes")
    }

    // MARK: - Recording

    @Test func recordingAppendsAndCapsAtTheLastTen() {
        var h = ProbeDurationHistory()
        for i in 1...13 { h = h.recording(lookups: 3, streams: 3, seconds: 100 + Double(i) * 10, contended: false) }
        #expect(h.runs.count == 10)
        #expect(h.runs.first?.seconds == 140)   // the first three fell off the front
        #expect(h.runs.last?.seconds == 230)
    }

    // A sample that cannot describe a round is refused at the door rather than stored and filtered later,
    // so ten one-show rechecks can never push the real evidence off the front of the file.
    @Test func degenerateAndIncomparableSamplesAreNeverStored() {
        var h = ProbeDurationHistory()
        h = h.recording(lookups: 0, streams: 3, seconds: 300, contended: false)      // no lookups
        h = h.recording(lookups: 3, streams: 0, seconds: 300, contended: false)      // no streams
        h = h.recording(lookups: 3, streams: 3, seconds: 0, contended: false)        // no duration
        h = h.recording(lookups: 3, streams: 3, seconds: -50, contended: false)      // clock skew
        h = h.recording(lookups: 1, streams: 1, seconds: 157, contended: false)      // one lookup, no round to measure
        h = h.recording(lookups: 3, streams: 1, seconds: 471, contended: false)      // sequential
        h = h.recording(lookups: 3, streams: 9, seconds: 300, contended: false)      // more streams than lookups: impossible
        #expect(h.runs.isEmpty)
    }

    // A round longer than the run's own stall warning is not a pace, it is a run that went wrong, and one
    // of those in the file would double every wait the bar quotes afterwards.
    @Test func anAbsurdlyLongRoundIsNeverStored() {
        var h = ProbeDurationHistory()
        h = h.recording(lookups: 3, streams: 3, seconds: RunTimeouts.reachabilityProbe + 1, contended: false)
        #expect(h.runs.isEmpty)
        h = h.recording(lookups: 20, streams: 10, seconds: RunTimeouts.reachabilityProbe * 2, contended: false)   // 2 rounds
        #expect(h.runs.count == 1)
    }

    // MARK: - Nothing parsed from disk feeds the average directly (L50)

    // The file is not user data and nothing repairs it, so a corrupt or hand-edited one must read as no
    // evidence at all. The failure that matters is the other one: a garbage number landing in the pool
    // and the bar quoting a wait nobody measured.
    @Test func anUnreadableHistoryFileTeachesNothingRatherThanZero() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-duration-bad-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("this is not json".utf8).write(to: url)

        let loaded = ProbeDurationHistoryStore.load(from: url)
        #expect(loaded.runs.isEmpty)
        #expect(loaded.learnedSecondsPerRound(contended: false) == nil)
        #expect(ProbeSelection.secondsPerRound(learnedFrom: loaded, contended: false) == ProbeSelection.fallbackSecondsPerRound)
    }

    // A file that parses but holds nonsense (an older shape, a hand edit, a zero written by a bug) is the
    // same answer: every stored run is re-judged on the way out, not trusted for having been written.
    @Test func storedRunsAreReJudgedOnRead() {
        let poisoned = history([(3, 3, 300), (3, 3, 300), (3, 3, 300), (3, 3, 0), (0, 0, 99_999)])
        #expect(poisoned.learnedSecondsPerRound(contended: false) == 300)
    }

    @Test func aMissingFileReadsAsNoHistoryNotAnError() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-duration-missing-\(UUID().uuidString).json")
        #expect(ProbeDurationHistoryStore.load(from: url).runs.isEmpty)
    }

    @Test func theStoreReadsBackWhatItWrote() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-duration-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        ProbeDurationHistoryStore.record(.init(lookups: 4, streams: 4, seconds: 240, contended: false), at: url)
        ProbeDurationHistoryStore.record(.init(lookups: 4, streams: 4, seconds: 240, contended: false), at: url)
        #expect(ProbeDurationHistoryStore.load(from: url).runs.count == 2)
        #expect(ProbeDurationHistoryStore.load(from: url).learnedSecondsPerRound(contended: false) == nil)

        ProbeDurationHistoryStore.record(.init(lookups: 4, streams: 4, seconds: 240, contended: false), at: url)
        #expect(ProbeDurationHistoryStore.load(from: url).learnedSecondsPerRound(contended: false) == 240)
    }

    @Test func recordingNothingIsANoOp() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-duration-nil-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        ProbeDurationHistoryStore.record(nil, at: url)
        #expect(ProbeDurationHistoryStore.load(from: url).runs.isEmpty)
    }
}

// #1616: reading what a finished run actually cost, out of the file the runner wrote it into.
//
// `runCost` is added to `overture-prep-results.json` by `mac/scripts/lib/models.sh` after the run has
// finished, and `docs/contracts.md` states the split this depends on: `recorded: true` carries `durationMs`,
// and `recorded: false` carries NO `durationMs` key at all, only `partialDurationMs`. A partial is one dead
// chunk short of the run's real wall clock, so it must never be read as the whole.
@Suite("Reading a run's recorded cost (#1616)")
struct RecordedRunCostTests {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    @Test func aCompleteRecordYieldsItsWallClockAndItsStreams() throws {
        // The one real record on this Mac, 2026-08-07: a three-chunk check, 389906ms.
        let cost = try #require(RecordedRunCost.complete(from: data("""
        {"version":6,"results":[],"runCost":{"recorded":true,"usd":5.395423,"durationMs":389906,"streams":3}}
        """)))
        #expect(cost.streams == 3)
        #expect(abs(cost.seconds - 389.906) < 0.001)
    }

    // Every one of these teaches nothing. None of them may become a zero, and none may become a number
    // that quietly makes the estimate absurd (L50).
    @Test func nothingUsableReadsAsNothing() {
        #expect(RecordedRunCost.complete(from: data("not json at all")) == nil)
        #expect(RecordedRunCost.complete(from: Data()) == nil)
        #expect(RecordedRunCost.complete(from: data(#"{"version":6}"#)) == nil)          // no runCost
        #expect(RecordedRunCost.complete(from: data(#"{"runCost":{}}"#)) == nil)         // empty runCost
        // A partial run: the contract keeps durationMs out of it entirely, and partialDurationMs is not it.
        #expect(RecordedRunCost.complete(from: data("""
        {"runCost":{"recorded":false,"streams":8,"streamsRecorded":3,"partialDurationMs":120000}}
        """)) == nil)
        // Present but unusable.
        #expect(RecordedRunCost.complete(from: data(#"{"runCost":{"recorded":true,"durationMs":"390000","streams":3}}"#)) == nil)
        #expect(RecordedRunCost.complete(from: data(#"{"runCost":{"recorded":true,"durationMs":0,"streams":3}}"#)) == nil)
        #expect(RecordedRunCost.complete(from: data(#"{"runCost":{"recorded":true,"durationMs":-5,"streams":3}}"#)) == nil)
        #expect(RecordedRunCost.complete(from: data(#"{"runCost":{"recorded":true,"durationMs":390000}}"#)) == nil)
        #expect(RecordedRunCost.complete(from: data(#"{"runCost":{"recorded":true,"durationMs":390000,"streams":0}}"#)) == nil)
        // "recorded" is the gate, so anything that is not a plain true is refused rather than coerced.
        #expect(RecordedRunCost.complete(from: data(#"{"runCost":{"durationMs":390000,"streams":3}}"#)) == nil)
        #expect(RecordedRunCost.complete(from: data(#"{"runCost":{"recorded":1,"durationMs":390000,"streams":3}}"#)) == nil)
    }
}

// #1616: which finished checks are allowed to teach the estimate anything.
@Suite("What a finished check teaches (#1616)")
struct ProbeRunPaceRecordingTests {

    private let good = RecordedRunCost(seconds: 300, streams: 3, contended: false)

    @Test func aCompleteUncancelledCheckIsRecorded() throws {
        let sample = try #require(ProbeRunPaceRecording.sample(lookups: 3, cost: good, cancelled: false))
        #expect(sample == ProbeDurationHistory.Run(lookups: 3, streams: 3, seconds: 300, contended: false))
    }

    // A check Dan stopped did not finish its work, so its wall clock is not a pace. The recorded cost is
    // usually incomplete too, but the two are separate facts and neither is allowed to stand alone.
    @Test func aCancelledCheckTeachesNothing() {
        #expect(ProbeRunPaceRecording.sample(lookups: 3, cost: good, cancelled: true) == nil)
    }

    @Test func aRunWithNoReadableCostTeachesNothing() {
        #expect(ProbeRunPaceRecording.sample(lookups: 3, cost: nil, cancelled: false) == nil)
    }

    // The lookup count comes from the check's own marker, written when the run launched. A marker from a
    // build before that field existed decodes as nil, and a run whose size is unknown cannot say how many
    // rounds its wall clock covered.
    @Test func aRunOfUnknownSizeTeachesNothing() {
        #expect(ProbeRunPaceRecording.sample(lookups: nil, cost: good, cancelled: false) == nil)
    }

    @Test func anIncomparableRunTeachesNothing() {
        #expect(ProbeRunPaceRecording.sample(lookups: 1, cost: RecordedRunCost(seconds: 157, streams: 1, contended: false),
                                             cancelled: false) == nil)
        #expect(ProbeRunPaceRecording.sample(lookups: 3, cost: RecordedRunCost(seconds: 471, streams: 1, contended: false),
                                             cancelled: false) == nil)
    }
}

// #1616: a learner nothing feeds and nothing reads is indistinguishable from no learner at all (L3), and
// both ends of this live in a SwiftUI view where no behavioural test can reach them (#863).
@Suite("The learned wait is wired at both ends (#1616)")
struct ProbePaceWiringGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    // The writing end: a finished check hands its size and its recorded cost to the store.
    @Test func aFinishedCheckRecordsItsPace() {
        let root = source("Overture/App/RootView.swift")
        // #2978: the SLOT travels with it. The call used to name no slot and the recording read the prep
        // slot's results file for every check, so this string is what changed when that was fixed. As
        // code rather than raw text, so re-wrapping the call cannot turn this red for formatting (#2543).
        #expect(SourceGuardHelper.containsCode(
            "recordCheckPace(slot: slot, lookups: checkLookups, cancelled: report.cancelled)", in: root))
        #expect(root.contains("ProbeDurationHistoryStore.record("))
        #expect(root.contains("ProbeRunPaceRecording.sample(lookups: lookups,"))
    }

    // Read BEFORE the settle, because the settle clears the marker the count lives in. A read after it
    // would compile, run, and quietly record nothing forever.
    @Test func theRunsSizeIsReadBeforeTheSettleClearsIt() throws {
        let root = source("Overture/App/RootView.swift")
        let read = try #require(root.range(of: "let checkLookups = ((try? ReachabilityProbeMarker.read"))
        let settle = try #require(root.range(of: "PrepQueueService.settleReachabilityProbe(slot: slot, into: context"))
        #expect(read.lowerBound < settle.lowerBound)
    }

    @Test func aLaunchingCheckStampsHowManyLookupsItHas() {
        #expect(source("Overture/Integration/PrepQueueService.swift").contains("lookups: queue.items.count"))
    }

    // The reading end: every surface that quotes a wait asks for the learned figure. A single one left on
    // the default would show Dan a different wait for the same run depending on how he started it.
    @Test func everySurfaceQuotingAWaitAsksForTheLearnedPace() {
        #expect(source("Overture/UI/ProbeSelectionBar.swift")
            .contains("secondsPerRound: ProbeSelection.liveSecondsPerRound()"))
        let queue = source("Overture/UI/QueueView.swift")
        // #2543: the call as CODE, not as the two lines it is currently wrapped into. This is the exact
        // shape #1900 hit, where adding an argument re-wrapped a call and turned its guard red for
        // formatting while nothing was unwired.
        #expect(SourceGuardHelper.containsCode(
            "summarizeShowsACheckMissed( count: keys.count, secondsPerRound: ProbeSelection.liveSecondsPerRound())",
            in: queue))
        #expect(queue.contains("secondsPerRound: ProbeSelection.liveSecondsPerRound())"))
    }
}
