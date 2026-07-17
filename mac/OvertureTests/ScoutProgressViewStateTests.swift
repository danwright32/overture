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
struct ScoutProgressViewStateTests {
    private func allTexts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    private func snapshot(_ name: String?, _ completed: Int, _ total: Int) -> () -> ScoutProgressView.Snapshot {
        { ScoutProgressView.Snapshot(sourceName: name, completed: completed, total: total) }
    }

    // MARK: - The pure copy

    @Test func phaseTitlesAreDistinctAndStable() {
        #expect(ScoutProgressCopy.title(.scouting) == "Scouting")
        #expect(ScoutProgressCopy.title(.reading) == "Reading calendars")
    }

    @Test func theSourceLineNamesTheSourceAndItsPositionWhenThereAreSeveral() {
        #expect(ScoutProgressCopy.sourceLine(name: "Carnegie Hall", completed: 3, total: 9)
                == "Carnegie Hall · 3 of 9")
    }

    // A single-item run (a pasted lead, #1036) shows just the name: "1 of 1" is noise, so the count is
    // shown only when there is genuinely more than one source to get through.
    @Test func theSourceLineDropsTheCountForASingleSourceRun() {
        #expect(ScoutProgressCopy.sourceLine(name: "Some Org", completed: 1, total: 1) == "Some Org")
    }

    @Test func theSourceLineShowsJustTheCountWhenTheSourceIsntKnownYet() {
        #expect(ScoutProgressCopy.sourceLine(name: nil, completed: 2, total: 5) == "2 of 5")
    }

    @Test func theSourceLineIsNilWhenThereIsNeitherANameNorAMeaningfulCount() {
        #expect(ScoutProgressCopy.sourceLine(name: nil, completed: 0, total: 0) == nil)
        #expect(ScoutProgressCopy.sourceLine(name: "Org", completed: 0, total: 0) == "Org")
    }

    // MARK: - The rendered states

    @Test func runningNamesThePhaseTheSourceAndTheElapsedCounter() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1042)   // 42s in, well under the scout timeout
        let view = ScoutProgressView(phase: .scouting, since: since,
                                     snapshot: snapshot("Carnegie Hall", 3, 9)).content(now: now)
        let texts = try allTexts(view)

        #expect(texts.contains("Scouting"))
        #expect(texts.contains("Carnegie Hall · 3 of 9"))
        #expect(texts.contains(RunProgress.elapsedLabel(since: since, now: now)!))
        #expect((try? view.inspect().find(ViewType.ProgressView.self)) != nil)
        #expect(!texts.contains { $0.contains("looks stuck") })
        #expect((try? view.inspect().find(button: "Retry")) == nil)
    }

    @Test func theReadingPhaseNamesItselfDistinctlyFromScouting() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1030)
        let view = ScoutProgressView(phase: .reading, since: since,
                                     snapshot: snapshot("Kaufman Music Center", 2, 5)).content(now: now)
        #expect(try allTexts(view).contains("Reading calendars"))
        #expect(try allTexts(view).contains("Kaufman Music Center · 2 of 5"))
    }

    // Past the phase's timeout with a dead heartbeat: a visibly distinct stalled state, not a spinner
    // that looks identical to a live run. Reading's window is the long scoutExtract one (10m), so a run
    // 11 minutes in with runAlive false is stuck.
    @Test func stalledShowsTheStuckSentenceAWarningAndAWorkingRetry() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = since.addingTimeInterval(RunTimeouts.scoutExtract + 30)
        let elapsed = RunProgress.elapsedLabel(since: since, now: now)!
        var retried = false
        let view = ScoutProgressView(phase: .reading, since: since,
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
        let view = ScoutProgressView(phase: .reading, since: since,
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
        let view = ScoutProgressView(phase: .scouting, since: since,
                                     snapshot: snapshot("Carnegie Hall", 1, 9),
                                     onHide: { hidden = true }).content(now: now)
        try view.inspect().find(button: "Hide").tap()
        #expect(hidden == true)
    }
}
