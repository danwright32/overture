import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #1034: the takeover scout-progress modal. Its working / still-alive / stalled decision comes from the
// shared RunProgress.liveness (already unit-tested), but the SwiftUI rendering that consumes it (does
// the stalled branch show Retry, does runAlive suppress it, does it name the source and count) has to be
// exercised too. Calls `content(now:)` directly with a fixed instant, exactly as LiveRunLabelViewState
// tests do (see LiveRunLabel.swift's #470 comment: `body` wraps it in a real TimelineView).
@MainActor
@Suite("Scout progress modal view state (#1034)")
struct RunProgressViewStateTests {
    private func allTexts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    private func snapshot(_ name: String?, _ completed: Int, _ total: Int) -> () -> RunProgressView.Snapshot {
        { RunProgressView.Snapshot(sourceName: name, completed: completed, total: total) }
    }

    // MARK: - The pure copy

    @Test func phaseTitlesAreDistinctAndStable() {
        #expect(RunProgressCopy.title(.scouting) == "Scouting")
        #expect(RunProgressCopy.title(.reading) == "Reading calendars")
    }

    // #1322: a reachability probe reuses the shared prep runner and takeover, but the takeover is worded
    // for a Prep ("Prepping"). A probe gets its own honest label so the in-progress state names what is
    // actually running, per the app's progress principle.
    @Test func theProbingPhaseNamesItselfDistinctlyFromPrepping() {
        #expect(RunProgressCopy.title(.probing) == "Checking reachability")
        #expect(RunProgressCopy.title(.probing) != RunProgressCopy.title(.prepping))
    }

    // #1124: the name (the source being read RIGHT NOW) and the count (how many are DONE) are two
    // uncoordinated facts, so they must never be glued into "name · N of M", which read as if the number
    // indexed the named source (and was off by one). The current source is its own line, just the name,
    // carrying no count and no middot.
    @Test func theCurrentSourceLineIsJustTheNameNeverPairedWithACount() {
        let line = RunProgressCopy.currentSourceLine(name: "Carnegie Hall")
        #expect(line == "Carnegie Hall")
        #expect(!(line ?? "").contains("·"))
        #expect(!(line ?? "").contains(" of "))
    }

    @Test func theCurrentSourceLineIsNilWhenTheSourceIsntKnownYet() {
        #expect(RunProgressCopy.currentSourceLine(name: nil) == nil)
    }

    // #1124: overall progress is a SEPARATE line, worded as a completed count ("done") so it cannot read
    // as the named source's position, and carrying no name and no middot.
    @Test func theOverallProgressLineReadsAsACompletedCountNotAPosition() {
        let line = RunProgressCopy.overallProgressLine(completed: 3, total: 9)
        #expect(line == "3 of 9 done")
        #expect(!(line ?? "").contains("·"))
    }

    // A single-item run (a pasted lead, #1036) shows no count line: "1 of 1 done" is noise, so the count
    // shows only when there is genuinely more than one source to get through.
    @Test func theOverallProgressLineIsHiddenForASingleSourceRun() {
        #expect(RunProgressCopy.overallProgressLine(completed: 1, total: 1) == nil)
    }

    @Test func theOverallProgressLineIsNilWhenThereIsNoMeaningfulCount() {
        #expect(RunProgressCopy.overallProgressLine(completed: 0, total: 0) == nil)
    }

    // #1427: the predicted-remaining line reads as an approximation ("~") in minutes and seconds, rounded
    // to the nearest ten seconds so it never implies a precision an averaged pace does not have.
    @Test func theRemainingLineReadsAsAnApproximateDuration() {
        #expect(RunProgressCopy.remainingLine(150) == "~2m 30s remaining")
        #expect(RunProgressCopy.remainingLine(120) == "~2m remaining")   // no dangling "0s"
        #expect(RunProgressCopy.remainingLine(30) == "~30s remaining")
        #expect(RunProgressCopy.remainingLine(152) == "~2m 30s remaining")   // rounded to the nearest 10s
    }

    // No line when there is nothing to predict (no estimate available) or the run is effectively done.
    @Test func theRemainingLineIsNilWhenThereIsNothingToSay() {
        #expect(RunProgressCopy.remainingLine(nil) == nil)
        #expect(RunProgressCopy.remainingLine(0) == nil)
        #expect(RunProgressCopy.remainingLine(3) == nil)   // rounds to zero, so the run is basically done
    }

    // MARK: - The rendered states

    @Test func runningNamesThePhaseTheSourceAndTheElapsedCounter() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1042)   // 42s in, well under the scout timeout
        let view = RunProgressView(phase: .scouting, since: since,
                                     snapshot: snapshot("Carnegie Hall", 3, 9)).content(now: now)
        let texts = try allTexts(view)

        #expect(texts.contains("Scouting"))
        // #1124: the name and the count are two separate lines, never glued with a middot.
        #expect(texts.contains("Carnegie Hall"))
        #expect(texts.contains("3 of 9 done"))
        #expect(!texts.contains { $0.contains("·") })
        #expect(texts.contains(RunProgress.elapsedLabel(since: since, now: now)!))
        #expect((try? view.inspect().find(ViewType.ProgressView.self)) != nil)
        #expect(!texts.contains { $0.contains("looks stuck") })
        #expect((try? view.inspect().find(button: "Retry")) == nil)
    }

    @Test func theReadingPhaseNamesItselfDistinctlyFromScouting() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1030)
        let view = RunProgressView(phase: .reading, since: since,
                                     snapshot: snapshot("Kaufman Music Center", 2, 5)).content(now: now)
        let texts = try allTexts(view)
        #expect(texts.contains("Reading calendars"))
        // #1124: the current calendar and the overall count read as two separate facts, never as
        // "Kaufman Music Center · 2 of 5" (which implied Kaufman was calendar #2 of 5).
        #expect(texts.contains("Kaufman Music Center"))
        #expect(texts.contains("2 of 5 done"))
        #expect(!texts.contains { $0.contains("·") })
    }

    // #1427: given enough history, the reading phase shows a predicted "~X remaining" from the learned pace
    // times the sources left. 5s/source over 5 sources with 2 done -> 3 left -> 15s.
    @Test func theReadingPhaseShowsThePredictedRemainingWhenHistoryExists() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1030)
        let history = RunDurationHistory(runs: [.init(sources: 10, seconds: 50),
                                                .init(sources: 10, seconds: 50),
                                                .init(sources: 10, seconds: 50)])   // 5s/source
        let view = RunProgressView(phase: .reading, since: since,
                                    snapshot: snapshot("Kaufman Music Center", 2, 5),
                                    durationHistory: { history }).content(now: now)
        #expect(try allTexts(view).contains("~20s remaining"))   // 15s rounds to nearest 10s
    }

    // The estimate is Reading-only and history-gated: the Scouting phase never shows it (its own timing is
    // out of scope), and a thin history shows nothing rather than a guess.
    @Test func noRemainingLineForScoutingOrWhenHistoryIsThin() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1030)
        let fullHistory = RunDurationHistory(runs: [.init(sources: 10, seconds: 50),
                                                    .init(sources: 10, seconds: 50),
                                                    .init(sources: 10, seconds: 50)])
        let scouting = RunProgressView(phase: .scouting, since: since,
                                       snapshot: snapshot("Carnegie Hall", 2, 5),
                                       durationHistory: { fullHistory }).content(now: now)
        #expect(!(try allTexts(scouting).contains { $0.contains("remaining") }))

        let thin = RunProgressView(phase: .reading, since: since,
                                   snapshot: snapshot("Kaufman Music Center", 2, 5),
                                   durationHistory: { RunDurationHistory(runs: [.init(sources: 5, seconds: 25)]) })
            .content(now: now)
        #expect(!(try allTexts(thin).contains { $0.contains("remaining") }))
    }

    // Past the phase's timeout with a dead heartbeat: a visibly distinct stalled state, not a spinner
    // that looks identical to a live run. Reading's window is the long scoutExtract one (10m), so a run
    // 11 minutes in with runAlive false is stuck.
    @Test func stalledShowsTheStuckSentenceAWarningAndAWorkingRetry() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = since.addingTimeInterval(RunTimeouts.scoutExtract + 30)
        let elapsed = RunProgress.elapsedLabel(since: since, now: now)!
        var retried = false
        let view = RunProgressView(phase: .reading, since: since,
                                     snapshot: snapshot("Kaufman Music Center", 2, 5),
                                     heartbeat: { .stale }, onRetry: { retried = true }).content(now: now)

        #expect(try allTexts(view).contains(RunProgress.stalledLabel("Reading calendars", elapsed: elapsed)))
        #expect((try? view.inspect().find(ViewType.ProgressView.self)) == nil,
                "a stalled run must not keep spinning as though it were alive")
        let retry = try view.inspect().find(button: "Retry")
        try retry.tap()
        #expect(retried == true)
    }

    // #1822, the screen Dan actually reported: a run that has FINISHED (its runner deleted the marker in
    // its exit trap) sits here for up to three seconds before the watcher closes the sheet. It must not
    // spend those seconds accusing itself of being stuck, which is what every Prep run long enough to
    // pass its timeout did.
    @Test func aFinishedRunSaysItIsFinishingRatherThanStuck() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = since.addingTimeInterval(RunTimeouts.scoutExtract + 30)
        let elapsed = RunProgress.elapsedLabel(since: since, now: now)!
        let view = RunProgressView(phase: .reading, since: since,
                                   snapshot: snapshot("Kaufman Music Center", 5, 5),
                                   heartbeat: { .absent }).content(now: now)

        #expect(try allTexts(view).contains(RunProgress.finishingLabel(elapsed: elapsed)))
        #expect(!(try allTexts(view).contains { $0.contains("looks stuck") }),
                "a run that ended cleanly must never be called stuck")
        // Still visibly in flight rather than a dead screen, and still named, so the last thing on screen
        // is not a subject change.
        #expect((try? view.inspect().find(ViewType.ProgressView.self)) != nil)
        #expect(try allTexts(view).contains("Reading calendars"))
    }

    // The other half, and the one that keeps the warning meaningful: a marker LEFT BEHIND by a run that
    // died is still reported stuck. Same elapsed, same phase, opposite verdict, decided only by whether
    // the marker is gone or merely stale.
    @Test func aMarkerLeftBehindIsStillReportedStuck() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = since.addingTimeInterval(RunTimeouts.scoutExtract + 30)
        let view = RunProgressView(phase: .reading, since: since,
                                   snapshot: snapshot("Kaufman Music Center", 5, 5),
                                   heartbeat: { .stale }).content(now: now)
        #expect(try allTexts(view).contains { $0.contains("looks stuck") })
    }

    // A run past its wall-clock timeout whose heartbeat still says it is alive renders as running, not
    // stalled: the reading phase legitimately runs long, and the marker is the real liveness signal.
    @Test func pastTimeoutButAliveRendersAsRunningNotStalled() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = since.addingTimeInterval(RunTimeouts.scoutExtract + 30)
        let view = RunProgressView(phase: .reading, since: since,
                                     snapshot: snapshot("Kaufman Music Center", 2, 5),
                                     heartbeat: { .beating }).content(now: now)
        #expect(!(try allTexts(view).contains { $0.contains("looks stuck") }))
        #expect(try allTexts(view).contains("Reading calendars"))
    }

    // Dismissing only hides: the modal offers a Hide control that fires the caller's closure (RootView
    // keeps the run going and shows a reopen affordance).
    @Test func theHideControlFiresWithoutTouchingTheRun() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1010)
        var hidden = false
        let view = RunProgressView(phase: .scouting, since: since,
                                     snapshot: snapshot("Carnegie Hall", 1, 9),
                                     onHide: { hidden = true }).content(now: now)
        try view.inspect().find(button: "Hide").tap()
        #expect(hidden == true)
    }

    // #1037: a real Cancel that STOPS the run, distinct from Hide. Present only when the caller supplies
    // one (the takeover does; AddLeadSheet supplies its own).
    @Test func theCancelControlFiresWhenProvided() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1010)
        var cancelled = false
        let view = RunProgressView(phase: .reading, since: since,
                                     snapshot: snapshot("Kaufman Music Center", 2, 5),
                                     onCancel: { cancelled = true }).content(now: now)
        try view.inspect().find(button: "Cancel").tap()
        #expect(cancelled == true)
    }

    // #1684. Dan, mid-run: "I'm trying to click cancel and it's doing nothing." The click WAS honoured;
    // the panel just went on showing a spinner, the phase title, "1 of 5 done", a climbing timer and a
    // Cancel button, identical to a working run, so he pressed it again and called it broken.
    //
    // Once the stop is acknowledged the button is gone, and the panel says what is happening.
    @Test func theCancelControlDisappearsOnceTheStopIsAcknowledged() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1070)
        let view = RunProgressView(phase: .probing, since: since,
                                   snapshot: snapshot(nil, 1, 5),
                                   heartbeat: { .beating },
                                   onCancel: { },
                                   cancelRequested: { true }).content(now: now)

        #expect((try? view.inspect().find(button: "Cancel")) == nil,
                "a control that keeps offering itself after being pressed reads as broken")
        #expect(try allTexts(view).contains { $0.contains("Stopping") })
    }

    // The same panel with no stop requested still offers Cancel, so the test above cannot pass for the
    // wrong reason (a probing panel that simply never shows one).
    @Test func theCancelControlIsStillThereBeforeAnyStopIsRequested() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1070)
        let view = RunProgressView(phase: .probing, since: since,
                                   snapshot: snapshot(nil, 1, 5),
                                   heartbeat: { .beating },
                                   onCancel: { },
                                   cancelRequested: { false }).content(now: now)

        #expect((try? view.inspect().find(button: "Cancel")) != nil)
        #expect(try allTexts(view).contains { $0.contains("Stopping") } == false)
    }

    // The count is dropped while stopping, deliberately: it can no longer climb, and a progress line that
    // has stopped moving is the thing that made a stopping run look like a working one.
    @Test func thestoppingPanelDropsTheProgressCountItCanNoLongerAdvance() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1070)
        let view = RunProgressView(phase: .probing, since: since,
                                   snapshot: snapshot(nil, 1, 5),
                                   heartbeat: { .beating },
                                   onCancel: { },
                                   cancelRequested: { true }).content(now: now)

        #expect(try allTexts(view).contains { $0.contains("1 of 5") } == false)
    }

    // On the one phase that SPENDS, the wait explains itself: the lookups still finishing are why the
    // stop is not instant, and their answers are still saved.
    @Test func thestoppingPanelExplainsTheWaitOnAPaidRun() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1070)
        let probing = RunProgressView(phase: .probing, since: since, snapshot: snapshot(nil, 1, 5),
                                      heartbeat: { .beating }, onCancel: { },
                                      cancelRequested: { true }).content(now: now)
        let prepping = RunProgressView(phase: .prepping, since: since, snapshot: snapshot(nil, 1, 5),
                                       heartbeat: { .beating }, onCancel: { },
                                       cancelRequested: { true }).content(now: now)

        #expect(try allTexts(probing).contains(ReachabilityProbeCopy.stoppingSpendNote))
        #expect(try allTexts(prepping).contains(ReachabilityProbeCopy.stoppingSpendNote) == false,
                "a run that spends nothing per item must not carry a sentence about spending")
    }

    // MARK: - The sweep's own heartbeat (#1530)

    // A manual sweep walks all 62 sources since #1518, so it routinely passes RunTimeouts.scout (3m) and
    // used to show the rust "looks stuck" warning moments before every run finished. A sweep whose count
    // is still advancing reads as working, however long it has been going.
    @Test func aScoutSweepStillLandingSourcesRendersAsRunningPastTheCeiling() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = since.addingTimeInterval(RunTimeouts.scout + 90)
        let view = RunProgressView(phase: .scouting, since: since,
                                     snapshot: { .init(sourceName: "Jalopy Theatre", completed: 55, total: 62,
                                                       advancedAt: now.addingTimeInterval(-8)) })
            .content(now: now)
        let texts = try allTexts(view)

        #expect(!texts.contains { $0.contains("looks stuck") })
        #expect(texts.contains("Scouting"))
        #expect(texts.contains("55 of 62 done"))
        #expect((try? view.inspect().find(ViewType.ProgressView.self)) != nil)
    }

    // The other half of the same claim: a sweep that stopped advancing still reaches the stalled state, so
    // this did not trade a false "stuck" for a spinner that never admits a wedged run.
    @Test func aScoutSweepWedgedOnOneSourceStillRendersAsStalled() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = since.addingTimeInterval(RunTimeouts.scout + 90)
        let elapsed = RunProgress.elapsedLabel(since: since, now: now)!
        let view = RunProgressView(phase: .scouting, since: since,
                                     snapshot: { .init(sourceName: "Jalopy Theatre", completed: 55, total: 62,
                                                       advancedAt: now.addingTimeInterval(-(RunTimeouts.scoutSourceStep + 5))) })
            .content(now: now)

        #expect(try allTexts(view).contains(RunProgress.stalledLabel("Scouting", elapsed: elapsed)))
        #expect((try? view.inspect().find(ViewType.ProgressView.self)) == nil,
                "a wedged sweep must not keep spinning as though it were alive")
    }

    // A sweep that has not landed a single source has no heartbeat to trust, so the wall-clock ceiling
    // still decides and the stalled state is reached exactly as before.
    @Test func aSweepThatNeverLandedASourceStalledAtTheCeilingAsBefore() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = since.addingTimeInterval(RunTimeouts.scout + 5)
        let view = RunProgressView(phase: .scouting, since: since,
                                     snapshot: snapshot(nil, 0, 62)).content(now: now)
        #expect(try allTexts(view).contains { $0.contains("looks stuck") })
    }

    @Test func thereIsNoCancelControlWhenNoneIsProvided() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let view = RunProgressView(phase: .scouting, since: since,
                                     snapshot: snapshot("Carnegie Hall", 1, 9))
            .content(now: Date(timeIntervalSince1970: 1010))
        #expect((try? view.inspect().find(button: "Cancel")) == nil)
    }
}
