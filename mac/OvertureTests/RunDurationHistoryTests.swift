import Testing
import Foundation

// #1427: the learned pace behind the Reading-calendars "~X remaining" line. The prediction is only as
// honest as these rules: no estimate until a handful of runs exist, degenerate samples never stored, and
// the pace pooled so one tiny run cannot swing it. All pure, so the whole decision is tested without a run.
@Suite("Run-duration history (#1427)")
struct RunDurationHistoryTests {

    private func history(_ runs: [(sources: Int, seconds: Double)]) -> RunDurationHistory {
        RunDurationHistory(runs: runs.map { RunDurationHistory.Run(sources: $0.sources, seconds: $0.seconds) })
    }

    // MARK: - The estimate threshold

    @Test func noPaceUntilAHandfulOfRunsExist() {
        #expect(RunDurationHistory().secondsPerSource == nil)          // fresh install
        #expect(history([(5, 50)]).secondsPerSource == nil)           // one run is not enough
        #expect(history([(5, 50), (5, 50)]).secondsPerSource == nil)  // two still is not
        #expect(history([(5, 50), (5, 50), (5, 50)]).secondsPerSource != nil)  // three clears the bar
    }

    @Test func noRemainingEstimateWhenHistoryIsThin() {
        #expect(history([(5, 50)]).remaining(total: 10, completed: 2) == nil)
    }

    // MARK: - The pace itself

    // Pooled: total seconds over total sources, so a 40-source run weighs more than a 2-source one rather
    // than each run's ratio counting equally.
    @Test func paceIsPooledAcrossAllStoredRuns() {
        let h = history([(10, 100), (20, 100), (30, 100)])   // 300 seconds over 60 sources
        #expect(h.secondsPerSource == 5.0)
    }

    @Test func remainingIsPaceTimesTheSourcesLeft() {
        let h = history([(10, 100), (10, 100), (10, 100)])   // 300s over 30 sources = 10s per source
        #expect(h.remaining(total: 19, completed: 17) == 20.0)   // 2 sources left
        #expect(h.remaining(total: 19, completed: 4) == 150.0)   // 15 left
    }

    @Test func remainingClampsToZeroWhenNothingIsLeft() {
        let h = history([(10, 100), (10, 100), (10, 100)])
        #expect(h.remaining(total: 19, completed: 19) == 0)
        #expect(h.remaining(total: 19, completed: 25) == 0)   // completed can momentarily exceed total
    }

    // MARK: - Recording

    @Test func recordingAppendsAndCapsAtTheLastTen() {
        var h = RunDurationHistory()
        for i in 1...13 { h = h.recording(sources: 5, seconds: Double(i)) }
        #expect(h.runs.count == 10)
        #expect(h.runs.first?.seconds == 4)    // the first three (1,2,3) fell off the front
        #expect(h.runs.last?.seconds == 13)
    }

    // A cancelled/crashed sample with no sources, or a negative duration from clock skew, must never be
    // stored: it would drag the pace toward a lie.
    @Test func degenerateSamplesAreNeverStored() {
        var h = RunDurationHistory()
        h = h.recording(sources: 0, seconds: 50)     // no sources
        h = h.recording(sources: 5, seconds: 0)      // zero duration
        h = h.recording(sources: 5, seconds: -3)     // clock skew
        #expect(h.runs.isEmpty)
    }

    // MARK: - The store round-trips through disk

    @Test func theStoreReadsBackWhatItWrote() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-duration-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        RunDurationHistoryStore.record(sources: 8, seconds: 80, at: url)
        RunDurationHistoryStore.record(sources: 4, seconds: 40, at: url)
        let loaded = RunDurationHistoryStore.load(from: url)

        #expect(loaded.runs.count == 2)
        #expect(loaded.secondsPerSource == nil)   // still only two runs
        RunDurationHistoryStore.record(sources: 4, seconds: 40, at: url)
        #expect(RunDurationHistoryStore.load(from: url).secondsPerSource == 10.0)   // 160s / 16 sources
    }

    @Test func aMissingFileReadsAsEmptyHistoryNotAnError() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-duration-missing-\(UUID().uuidString).json")
        #expect(RunDurationHistoryStore.load(from: url).runs.isEmpty)
    }
}
