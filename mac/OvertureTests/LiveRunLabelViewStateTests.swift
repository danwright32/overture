import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #470: the working/still-alive/stalled decision (RunProgress.liveness) is pure and already fully
// unit tested, but the SwiftUI rendering that consumes it, does the stalled branch actually show
// a Retry button, does the runAlive override actually suppress it, has never been exercised by any
// test. Calls `content(now:)` directly with a fixed instant (see LiveRunLabel.swift's #470 comment
// for why: `body` wraps it in a real TimelineView, which would mean driving an async timer).
@MainActor
@Suite("LiveRunLabel view state (#470)")
struct LiveRunLabelViewStateTests {
    private func allTexts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    @Test func idleShowsTheBareCaptionWithNoElapsedCounterAndNoRetry() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let label = LiveRunLabel(base: "Sending", since: nil, timeout: 60)
        let texts = try allTexts(label.content(now: now))

        #expect(texts.contains("Sending…"))
        #expect(!texts.contains { $0.contains("looks stuck") })
        #expect((try? label.content(now: now).inspect().find(button: "Retry")) == nil)
    }

    @Test func runningShowsTheElapsedCounterAndNoRetry() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1010)   // 10s in, well under the 60s timeout
        let label = LiveRunLabel(base: "Sending", since: since, timeout: 60)
        let texts = try allTexts(label.content(now: now))

        #expect(texts.contains(RunProgress.spinnerLabel("Sending", since: since, now: now)))
        #expect(!texts.contains { $0.contains("looks stuck") })
        #expect((try? label.content(now: now).inspect().find(button: "Retry")) == nil)
    }

    @Test func stalledWithNoRetryShowsTheStuckCaptionAndNoButton() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1070)   // 70s in, past the 60s timeout
        let label = LiveRunLabel(base: "Sending", since: since, timeout: 60)
        let elapsed = RunProgress.elapsedLabel(since: since, now: now)!
        let texts = try allTexts(label.content(now: now))

        #expect(texts.contains("Sending looks stuck (\(elapsed))"))
        #expect((try? label.content(now: now).inspect().find(button: "Retry")) == nil)
    }

    // The direct regression test for the #468/#469 retry wiring: proves the harness can catch not
    // just "is a Retry button present" but "does tapping it actually fire the caller's closure".
    @Test func stalledWithRetrySuppliedShowsTheButtonAndFiresOnTap() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1070)
        var retried = false
        let label = LiveRunLabel(base: "Sending", since: since, timeout: 60, onRetry: { retried = true })

        let button = try label.content(now: now).inspect().find(button: "Retry")
        try button.tap()

        #expect(retried == true)
    }

    // #471: a past-timeout run whose real heartbeat says it's still genuinely alive must render as
    // running, not stalled, overriding the wall-clock-only result. Never exercised by any test
    // before this.
    @Test func pastTimeoutButRunAliveTrueRendersAsRunningNotStalled() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1070)   // past the 60s timeout
        let label = LiveRunLabel(base: "Drafting a reply", since: since, timeout: 60, runAlive: { true })
        let texts = try allTexts(label.content(now: now))

        #expect(!texts.contains { $0.contains("looks stuck") })
        #expect(texts.contains(RunProgress.spinnerLabel("Drafting a reply", since: since, now: now)))
    }
}
