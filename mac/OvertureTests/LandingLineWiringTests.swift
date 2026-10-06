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
        let call = try #require(root.range(of: "QueueView(deepLinkedKey:"), "the queue's construction moved")
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

    @Test func theDebugLaunchArgumentsAreTheOnesTheAppReads() throws {
        let script = try String(contentsOf: RepoRoot.mac.appendingPathComponent("scripts/run-debug.sh"), encoding: .utf8)
        #expect(script.contains("\"\(StoreLocation.storeFolderArgument)\""), "run-debug.sh hands a store folder flag the app does not read")
        #expect(script.contains("\"\(LandingPreview.argument)\""), "run-debug.sh hands a preview flag the app does not read")
    }
}
