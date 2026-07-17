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

    // #994. In the toolbar the label must not change width, because a toolbar item that grows reflows
    // its neighbours and shoves real buttons into the macOS ">>" overflow, exactly when Dan is watching
    // for a run to start. Dan's call: show the icon only and put the sentence in the tooltip.
    //
    // The sentence must survive somewhere, though. It is the whole "still alive" signal (#435), so it
    // moves to the tooltip verbatim rather than being dropped.
    @Test func theCompactLabelPrintsNoCaptionBesideItsIconSoTheToolbarCannotChangeWidth() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1010)
        let label = LiveRunLabel(base: "Reading calendars", since: since, timeout: 60,
                                 progressDetail: { "12 of 38" }, compact: true)
        let view = label.content(now: now)

        // The caption is what widens a toolbar item, and the HStack is what lays one out beside the
        // icon: the normal label is `HStack { ProgressView; Text }`. Asserting on the HStack rather
        // than on "is there any Text" is deliberate, because ViewInspector surfaces a `.help(...)`
        // tooltip as a Text too, so counting Texts cannot tell a caption from a tooltip.
        #expect((try? view.inspect().find(ViewType.HStack.self)) == nil,
                "a compact label lays nothing out beside its icon, so its width cannot move")

        // The words are not gone, they moved: the icon carries them as its tooltip.
        #expect(try view.inspect().find(ViewType.ProgressView.self).help().string()
                == label.helpText(now: now))
    }

    // Icon-only must not mean state-less. A spinner that looks identical whether the run is alive or
    // dead is the exact defect the standing progress rule forbids, so the three states stay
    // distinguishable AT A GLANCE by icon: spinner while alive, a warning symbol once stalled.
    @Test func theCompactLabelStillTellsAliveApartFromStalledWithoutHovering() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let alive = LiveRunLabel(base: "Reading calendars", since: since, timeout: 60, compact: true)
        let stalled = LiveRunLabel(base: "Reading calendars", since: since, timeout: 60, compact: true)

        // 10s in: still working, so a spinner and no warning.
        let running = alive.content(now: Date(timeIntervalSince1970: 1010))
        #expect((try? running.inspect().find(ViewType.ProgressView.self)) != nil)

        // 70s in, past the timeout: an actionable stalled state, visibly different.
        let stuck = stalled.content(now: Date(timeIntervalSince1970: 1070))
        #expect((try? stuck.inspect().find(ViewType.ProgressView.self)) == nil,
                "a stalled run must not keep spinning as though it were alive")
    }

    // The tooltip is now the only place the elapsed counter and the "N of M" progress live, so it has
    // to carry them, and it has to keep ticking. If this said only "Reading calendars", the compact
    // mode would have thrown away the still-alive signal rather than moved it.
    @Test func theCompactTooltipCarriesTheProgressAndTheElapsedCounter() {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1010)

        let help = LiveRunLabel(base: "Reading calendars", since: since, timeout: 60,
                                progressDetail: { "12 of 38" }, compact: true).helpText(now: now)

        #expect(help == RunProgress.spinnerLabel("Reading calendars", since: since, now: now,
                                                 detail: "12 of 38"))
        #expect(help.contains("12 of 38"))
        #expect(help.contains(RunProgress.elapsedLabel(since: since, now: now)!))
    }

    // #1003: the "N of M" progress must be re-read on every tick, not captured once at the caller's
    // last render. Before this, `progressDetail` was a plain String the enclosing view evaluated when
    // IT happened to re-render, which no timer drives: the count could sit at "3 of 38" for minutes
    // while only the elapsed counter (which has its own TimelineView) kept moving, reading as
    // "alive and progressing" whether or not anything was. Proven by a closure whose answer changes
    // between two renders: the label must show the NEW figure on the second render, which a value
    // captured once never could.
    @Test func theProgressDetailIsReReadEachRenderNotCapturedOnce() {
        let since = Date(timeIntervalSince1970: 1000)
        var current = "3 of 38"
        let label = LiveRunLabel(base: "Prepping", since: since, timeout: 60,
                                 progressDetail: { current }, compact: true)

        let first = label.helpText(now: Date(timeIntervalSince1970: 1010))
        #expect(first.contains("3 of 38"))

        current = "20 of 38"
        let second = label.helpText(now: Date(timeIntervalSince1970: 1020))
        #expect(second.contains("20 of 38"))
        #expect(!second.contains("3 of 38"))
    }

    @Test func theCompactTooltipSaysSoWhenTheRunLooksStuck() {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1070)   // past the 60s timeout
        let elapsed = RunProgress.elapsedLabel(since: since, now: now)!

        let help = LiveRunLabel(base: "Reading calendars", since: since, timeout: 60,
                                compact: true).helpText(now: now)

        #expect(help == RunProgress.stalledLabel("Reading calendars", elapsed: elapsed))
        #expect(help.contains("looks stuck"))
    }

    // The stalled icon must carry the tooltip too. This is the state Dan most needs words for: the run
    // is dead and the icon alone cannot say for how long.
    @Test func theCompactStalledIconStillCarriesItsTooltip() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1070)
        let label = LiveRunLabel(base: "Reading calendars", since: since, timeout: 60, compact: true)
        let view = label.content(now: now)

        #expect(try view.inspect().find(ViewType.Image.self).help().string() == label.helpText(now: now))
        #expect((try? view.inspect().find(ViewType.HStack.self)) == nil,
                "the stalled icon must not grow a caption either; it is in the same toolbar slot")
    }

    // The non-compact label is unchanged: every other surface (the reply drafter, Prep, Gmail connect)
    // has room for the sentence and keeps showing it, laid out beside the spinner.
    @Test func theNormalLabelStillPrintsItsSentenceBesideTheSpinner() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1010)
        let label = LiveRunLabel(base: "Sending", since: since, timeout: 60)
        let view = label.content(now: now)

        #expect((try? view.inspect().find(ViewType.HStack.self)) != nil)
        #expect(try allTexts(view).contains(RunProgress.spinnerLabel("Sending", since: since, now: now)))
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
