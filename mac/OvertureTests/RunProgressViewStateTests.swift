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
                                     runAlive: { false }, onRetry: { retried = true }).content(now: now)

        #expect(try allTexts(view).contains(RunProgress.stalledLabel("Reading calendars", elapsed: elapsed)))
        #expect((try? view.inspect().find(ViewType.ProgressView.self)) == nil,
                "a stalled run must not keep spinning as though it were alive")
        let retry = try view.inspect().find(button: "Retry")
        try retry.tap()
        #expect(retried == true)
    }

    // A run past its wall-clock timeout whose heartbeat still says it is alive renders as running, not
    // stalled: the reading phase legitimately runs long, and the marker is the real liveness signal.
    @Test func pastTimeoutButAliveRendersAsRunningNotStalled() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = since.addingTimeInterval(RunTimeouts.scoutExtract + 30)
        let view = RunProgressView(phase: .reading, since: since,
                                     snapshot: snapshot("Kaufman Music Center", 2, 5),
                                     runAlive: { true }).content(now: now)
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

    @Test func thereIsNoCancelControlWhenNoneIsProvided() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let view = RunProgressView(phase: .scouting, since: since,
                                     snapshot: snapshot("Carnegie Hall", 1, 9))
            .content(now: Date(timeIntervalSince1970: 1010))
        #expect((try? view.inspect().find(button: "Cancel")) == nil)
    }
}
