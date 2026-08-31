import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #2188: the press has to reach the thing that watches for its outcome.
//
// Everything else can be right and this can be missing, and the result is the state Dan met on
// 2026-08-06: the panel closes, the run refuses, and nothing ever says so. A rule and its wiring are two
// claims (L3), and this file holds the wiring one.
@Suite("Pressing Update starts something watching for how it went (#2188)")
struct UpdatePressIsWatchedTests {
    // The button reports the press rather than quietly dismissing the panel and forgetting it. Before
    // #2188 the sheet did its own dismissing and its own opening, so there was no moment anything else
    // could learn a press had happened.
    @Test func theUpdateButtonReportsThePress() throws {
        var pressed = false
        var dismissed = false
        let sheet = BuildFreshnessSheet(verdict: .behind(installedAt: Date(timeIntervalSince1970: 0),
                                                         shippedAt: Date(timeIntervalSince1970: 3600)),
                                        repoPath: "/code/overture",
                                        onUpdate: { pressed = true },
                                        onDismiss: { dismissed = true })

        try sheet.inspect().find(button: BuildFreshnessCopy.update).tap()

        #expect(pressed)
        #expect(dismissed == false, "the press is not a dismissal: the panel closing is the update starting")
    }

    @Test func notNowIsStillADismissal() throws {
        var pressed = false
        var dismissed = false
        let sheet = BuildFreshnessSheet(verdict: .behind(installedAt: Date(timeIntervalSince1970: 0),
                                                         shippedAt: Date(timeIntervalSince1970: 3600)),
                                        repoPath: "/code/overture",
                                        onUpdate: { pressed = true },
                                        onDismiss: { dismissed = true })

        try sheet.inspect().find(button: BuildFreshnessCopy.dismiss).tap()

        #expect(dismissed)
        #expect(pressed == false)
    }

    // And the notice hands that press to the watcher. This is a source guard rather than a rendered one
    // because the wiring lives in a ViewModifier's sheet closure, which nothing can construct from a
    // test: without it, every rule in UpdateAttemptStateTests passes while nothing in the app ever calls
    // `pressed`, and the whole channel is dormant (#887).
    @Test func theNoticeHandsThePressToTheWatcher() {
        let source = SourceGuardHelper.source("Overture/UI/BuildFreshnessSheet.swift")

        // #2726: the notice HOLDING one, not the type name occurring. The bare name is satisfied by the
        // initialiser line alone, so the stored property could have gone and this stayed green (L135).
        #expect(SourceGuardHelper.containsCode(
            "@State private var attempt: UpdateAttemptState", in: source),
                "the notice owns the watcher, or nothing is looking when the run reports back")
        #expect(SourceGuardHelper.containsCode(
            "_attempt = State(initialValue: UpdateAttemptState(directory: directory))", in: source),
                "and it has to be given the directory the run reports into")
        #expect(source.contains("attempt.pressed("),
                "the id UpdateCommandFile.open hands back has to reach the watcher, or it waits on a press it cannot recognise")
        #expect(source.contains("UpdateFailureSheet("),
                "the outcome has to have somewhere to appear")
    }
}
