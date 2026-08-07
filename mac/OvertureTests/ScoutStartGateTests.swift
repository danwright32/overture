import Testing
import Foundation

// #2208. Pressing Run scout while a previous read was still going swept all 68 sources, fetched and
// hashed them, worked out which had changed, and only then discovered it could not hand them off,
// reporting that a previous run was still reading.
//
// Nothing was lost and nothing was spent (the sweep is free), but Dan sat through a run whose main
// purpose could not happen, and the sentence that finally explained it said neither what to do nor when.
// The condition is knowable before the sweep starts: the same marker that refuses the hand-off at the end
// can be read at the beginning. Observed 2026-08-06.
@Suite("Say the reader is busy before spending a run on it (#2208)")
struct ScoutStartGateTests {
    @Test func apressWhileTheReaderIsBusyIsRefusedBeforeTheSweep() {
        let decision = ScoutStartGate.decide(readerIsRunning: true, depth: .readChanged, auto: false)
        guard case .waitForTheReader = decision else {
            Issue.record("a run that cannot hand anything over is not worth several minutes")
            return
        }
    }

    @Test func apressWithTheReaderFreeJustRuns() {
        #expect(ScoutStartGate.decide(readerIsRunning: false, depth: .readChanged, auto: false) == .start)
    }

    // The free daily watch pass never hands off (it is fetch and hash only), so a read in flight costs it
    // nothing. Blocking it would stop the one thing that notices a dead source within a day.
    @Test func thefreeDailyWatchPassIsNeverBlockedByAReadInFlight() {
        #expect(ScoutStartGate.decide(readerIsRunning: true, depth: .watchOnly, auto: true) == .start)
        #expect(ScoutStartGate.decide(readerIsRunning: true, depth: .watchOnly, auto: false) == .start)
    }

    // A run Dan did not start has nobody to tell, and refusing it quietly would be a scheduled run
    // silently not happening (L13).
    @Test func ascheduledRunIsNotSilentlyRefused() {
        #expect(ScoutStartGate.decide(readerIsRunning: true, depth: .readChanged, auto: true) == .start)
    }

    // MARK: - what it says

    // The three things, in order: what is happening, why pressing again now would not help, and when.
    @Test func thesentenceSaysWhatIsHappeningAndWhenToPressAgain() {
        let line = ScoutStartGate.message(remaining: nil)
        #expect(line.contains("still reading"))
        #expect(line.contains("Press Run scout again"))
        #expect(line.contains("finishes"))
    }

    @Test func alearnedEstimateIsIncludedWhenThereIsOne() {
        let line = ScoutStartGate.message(remaining: 4 * 60)
        #expect(line.contains("about 4m left"))
        #expect(line.contains("Press Run scout again"))
    }

    // No estimate, no claim. A guessed "about a minute" would be the app claiming something it has not
    // measured, on the one sentence whose entire job is to say when to come back (L11).
    @Test func nolearnedPaceMeansNoInventedEstimate() {
        let line = ScoutStartGate.message(remaining: nil)
        #expect(!line.contains("about"))
        #expect(!line.contains("left"))
    }

    // And under a minute is left out too: the shared duration buckets round it to "0m", and a sentence
    // saying a run has about no time left, beside a button that will not work yet, contradicts itself.
    @Test func anestimateUnderAMinuteIsNotShownAsZero() {
        let line = ScoutStartGate.message(remaining: 20)
        #expect(!line.contains("0m"))
        #expect(line.contains("Press Run scout again"))
    }

    // The decision carries that sentence, so the refusal cannot be silent.
    @Test func therefusalCarriesTheSentence() {
        let decision = ScoutStartGate.decide(readerIsRunning: true, depth: .readChanged, auto: false,
                                             remaining: 6 * 60)
        #expect(decision == .waitForTheReader(ScoutStartGate.message(remaining: 6 * 60)))
    }
}

// The wiring, which is a separate claim from the decision being right (L3).
@Suite("The scout press consults the gate (#2208)")
struct ScoutStartGateWiringTests {
    private var source: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    @Test func thepressChecksTheReaderBeforeSweeping() throws {
        let run = try #require(SourceGuardHelper.propertyBody(
            "only: Set<String>? = nil) {", in: source))
        #expect(run.contains("ScoutStartGate.decide("))
        #expect(run.contains("readerIsRunning: ScoutExtractService.isRunning(now: Date())"))
        // And it STOPS. A gate that decided, said so, and then swept anyway would be the defect with a
        // sentence attached, and "it mentions acknowledge somewhere" cannot tell the two apart: the
        // return is the whole behaviour (L1, caught by mutation).
        #expect(run.contains("feedback.acknowledge(why, tone: .warning)\n            return"),
                "the refusal has to return, or the sweep it refused runs anyway")

        // Before anything the run would have to undo: the generation bump, the takeover, the sweep.
        let decideAt = try #require(run.range(of: "ScoutStartGate.decide("))
        let sweepAt = try #require(run.range(of: "scoutGeneration += 1"))
        #expect(decideAt.lowerBound < sweepAt.lowerBound)
    }

    // The hand-off message is still reachable, because a read can begin DURING a sweep, and it now names
    // the next step rather than leaving Dan to infer it.
    @Test func thehandOffMessageNamesTheNextStep() {
        let scout = SourceGuardHelper.source("Overture/Integration/ScoutService.swift")
        #expect(scout.contains("press Run scout again once the reading finishes"))
        #expect(scout.contains("Nothing was lost"))
    }
}
