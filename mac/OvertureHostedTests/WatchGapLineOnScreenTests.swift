import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #2091: the detection reaching the SCREEN, which is a separate claim from the detection being right.
// WatchGapTests proves the arithmetic and ReconcileSchedulerTests proves the tick records the silence;
// neither would notice if this line rendered nothing. That gap is not hypothetical here: #2098 is open
// precisely because #2087's warning was shipped without anyone confirming it reaches a surface Dan
// looks at, and a guard that fires into a surface nobody looks at is indistinguishable from no guard.
@MainActor
@Suite("The watch gap line on screen (#2091)")
struct WatchGapLineOnScreenTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func scratch() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "watch-line-\(UUID().uuidString)"))
    }

    // A Mac that has been running Overture since before `at`, with `sleptSeconds` of observed sleep.
    private func liveSince(_ at: Date, sleptSeconds: Double = 0) -> WatchGap.Readings {
        WatchGap.Readings(sleptSeconds: sleptSeconds,
                          processStartedAt: at.timeIntervalSince1970 - 86_400,
                          quitCleanlyAt: 0,
                          bootedAt: at.timeIntervalSince1970 - 2 * 86_400)
    }

    private func texts(_ view: some View) -> [String] {
        ((try? view.inspect().findAll(ViewType.Text.self)) ?? []).compactMap { try? $0.string() }
    }

    // A healthy app draws nothing at all, so this is never the line that is always there and the
    // masthead does not grow a permanent row of reassurance.
    @Test func aHealthyWatchDrawsNothing() throws {
        let defaults = try scratch()
        WatchHeartbeatStore.stamp(now: now, readings: liveSince(now), into: defaults)
        let line = WatchGapLine(defaults: defaults)
        #expect(texts(line.content(now: now.addingTimeInterval(60))).isEmpty)
    }

    // The live fault: the ticks have stopped and the queue says so, in words, where Dan triages.
    @Test func aStoppedWatchPutsItsSentenceOnScreen() throws {
        let defaults = try scratch()
        WatchHeartbeatStore.stamp(now: now, readings: liveSince(now), into: defaults)
        let elapsed = 2 * 3_600.0
        let line = WatchGapLine(defaults: defaults)
        #expect(texts(line.content(now: now.addingTimeInterval(elapsed)))
                == ["Overture has not checked for replies or bookings in 2h"])
    }

    // The case that only exists because the outage is RECORDED: watching has resumed, the heartbeat is
    // fresh, and the queue still explains the three days of quiet Dan is looking at. Without the record
    // this renders nothing, which is the whole of #2091.
    @Test func aSilenceThatEndedIsStillExplainedOnScreen() throws {
        let defaults = try scratch()
        let threeDays = 3 * 86_400.0
        WatchHeartbeatStore.stamp(now: now, readings: liveSince(now), into: defaults)
        WatchHeartbeatStore.observeResume(now: now.addingTimeInterval(threeDays),
                                          readings: liveSince(now), intervalSeconds: 30 * 60,
                                          into: defaults)
        WatchHeartbeatStore.stamp(now: now.addingTimeInterval(threeDays), readings: liveSince(now),
                                  into: defaults)

        let line = WatchGapLine(defaults: defaults)
        #expect(texts(line.content(now: now.addingTimeInterval(threeDays + 720)))
                == ["Overture was not checking for replies or bookings for 3d, and resumed 12m ago"])
    }

    // And it is wired into the masthead, not merely built: a view nothing places renders nowhere.
    @Test func theMastheadDrawsTheLine() {
        let queue = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        let masthead = SourceGuardHelper.propertyBody(
            "agentInputs: AgentInputs) -> some View {", in: queue)
        #expect(masthead?.contains("WatchGapLine()") == true,
                "the queue masthead must draw the watch gap line")
    }
}
