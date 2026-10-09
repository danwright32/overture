import Testing
import Foundation

// #4338 (A10): the landing line is reached from the product, not only from the tests that build it (L718). RootView
// hands the queue real handlers, the queue's masthead draws the line, and the landing lines RootView used to put in
// the status line are on the landing line instead, so each is said once (L605). And the Debug launch arguments
// `run-debug.sh` hands the app are the ones the app reads, compared across the two files (L70).
@MainActor
@Suite("The landing line is wired from RootView through the queue's masthead (#4338)")
struct LandingLineWiringTests {
    private let root = SourceGuardHelper.source("Overture/App/RootView.swift")
    private let queue = SourceGuardHelper.source("Overture/UI/QueueView.swift")

    @Test func rootViewHandsTheQueueRealHandlers() throws {
        let call = try #require(root.range(of: "QueueView(engine:"), "the queue's construction moved")
        let rest = root[call.upperBound...]
        let handed = try #require(rest.range(of: "landingLine: LandingLineHandlers(perform:"),
                                  "RootView no longer hands the landing line its handlers")
        // Inside the same construction, before the next view is made.
        #expect(rest[..<handed.lowerBound].range(of: "onOpenURL") == nil)
    }

    @Test func theMastheadDrawsTheLandingLine() {
        #expect(queue.contains("LandingLine(handlers: landingLine)"))
    }

    // Each landing line used to be a status line; it is said on the landing line alone now.
    @Test func theLandingLinesAreNoLongerStatusLines() throws {
        for name in ["offerPendingScoutIngests", "sayRecovery", "announceInterruptedLandings", "surveyLandings"] {
            let body = try #require(SourceGuardHelper.bodyOfFunction(named: name, in: root), "\(name) moved")
            #expect(!body.contains("status.set("), Comment(rawValue: "\(name) still writes the status line"))
        }
    }

    // Any save of the main context ends the entry flush's standing state.
    @Test func aSaveOfTheMainContextEndsTheStuckEdits() {
        #expect(root.contains("ModelContext.didSave, object: context"))
        #expect(root.contains("EntryFlushRecord.shared.saveSucceeded()"))
    }

    // A preview of a landing in progress is applied after the launch sweep of kept results, which ends the line's
    // in progress state when it finishes: applied beside it, in a task of its own, the sweep cleared it and the
    // preview showed nothing on a store with kept results, which is what the synthetic store has.
    @Test func theDebugPreviewIsAppliedAfterTheLaunchSweep() throws {
        let sweep = try #require(root.range(of: "await offerPendingScoutIngests()\n"), "the launch sweep moved")
        let rest = root[sweep.upperBound...]
        let autoScout = try #require(rest.range(of: "autoScoutIfDue()"), "the launch's scheduled scout moved")
        #expect(rest[..<autoScout.lowerBound].contains("showLandingPreview(preview)"),
                "the preview is not applied between the launch sweep and the scheduled scout")
        #expect(root.components(separatedBy: "showLandingPreview(preview)").count == 2,
                "the preview is applied in more than one place")
    }

    @Test func theDebugLaunchArgumentsAreTheOnesTheAppReads() throws {
        let script = try String(contentsOf: RepoRoot.mac.appendingPathComponent("scripts/run-debug.sh"), encoding: .utf8)
        #expect(script.contains("\"\(StoreLocation.storeFolderArgument)\""), "run-debug.sh hands a store folder flag the app does not read")
        #expect(script.contains("\"\(LandingPreview.argument)\""), "run-debug.sh hands a preview flag the app does not read")
    }
}
