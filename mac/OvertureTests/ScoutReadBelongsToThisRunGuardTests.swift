import Testing
import Foundation

// #3887: the scout follows its OWN read, never whichever read ran last.
//
// The rule itself is pure and tested in DetachedRunOutcomeTests. What cannot be reached from there is the
// wiring: `watchScoutExtractRun` lives on a SwiftUI view and its callers are private, so what this asserts
// is that each caller still says which read it means. The defect was exactly a missing input, so a call
// site that stopped passing one is the way it comes back (L3: built is not wired).
@Suite("The scout's read watcher is told whose read it is (#3887)")
struct ScoutReadBelongsToThisRunGuardTests {
    private var source: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    // No zero-argument form, which is what makes every caller decide rather than inherit the old
    // behaviour by omission. A default value here would have left the defect in place at every site that
    // did not think about it (L621).
    @Test func theWatcherTakesTheBoundaryWithNoDefault() {
        #expect(!source.isEmpty, "RootView.swift could not be read, so this measured nothing")
        #expect(SourceGuardHelper.containsCode(
            "private func watchScoutExtractRun(callerStartedAt: Date?) async -> ScoutReadResult", in: source),
                "watchScoutExtractRun must take callerStartedAt, with no default")
        #expect(!SourceGuardHelper.containsCode("watchScoutExtractRun(callerStartedAt: Date? = nil)", in: source),
                "a default would let a caller inherit the old behaviour without saying so")
        #expect(!SourceGuardHelper.containsCode("watchScoutExtractRun()", in: source),
                "a caller is following a read without saying which one")
    }

    // The scout passes the moment IT began, not the read's own marker: the marker is the very thing that
    // can belong to an older run, so reading the boundary from it would compare a value with itself and
    // agree every time (L70).
    @Test func theScoutPassesItsOwnStart() {
        #expect(SourceGuardHelper.containsCode("watchScoutExtractRun(callerStartedAt: runBeganAt)", in: source),
                "the scout must follow the read against its own start")
        #expect(SourceGuardHelper.containsCode("let runBeganAt = Date()", in: source),
                "runScout captures its own start in a local, because scoutStartedAt is cleared before the read is followed")
        #expect(!SourceGuardHelper.containsCode(
            "watchScoutExtractRun(callerStartedAt: ScoutExtractService.lastRunStartedAt)", in: source),
                "the boundary may not be read from the same marker it exists to judge")
    }

    // The one caller that legitimately passes nil, asserted so it stays deliberate: at launch the run
    // being picked up started in a session that has ended, so any boundary would refuse all of them.
    @Test func reattachDeliberatelyPassesNoBoundary() {
        #expect(SourceGuardHelper.containsCode("watchScoutExtractRun(callerStartedAt: nil)", in: source))
        let calls = SourceGuardHelper.normalizedCode(source)
            .components(separatedBy: "watchScoutExtractRun(callerStartedAt: nil)").count - 1
        #expect(calls == 1,
                Comment(rawValue: "\(calls) callers follow any read at all. Only the launch reattach may, "
                        + "and it may because its run started in a session that has ended."))
    }

    // The ingest that the defect actually reached. It has one caller of its own beyond the watcher,
    // `keepCancelledRead`, and that one is reachable only through the watcher's `.producedResults`
    // branch, so it inherits the boundary rather than needing its own. Asserted because "it inherits it"
    // is a claim about the call graph, and a second direct caller would silently make it false (L281).
    @Test func nothingElseImportsTheReadDirectly() {
        let callers = SourceGuardHelper.normalizedCode(source)
            .components(separatedBy: "ingestScoutExtract()").count - 1
        #expect(callers == 3,
                Comment(rawValue: "ingestScoutExtract() appears \(callers) times (its declaration, the "
                        + "watcher's ingest, and keepCancelledRead). A new caller has to say which read "
                        + "it means, because this one does not ask."))
    }
}
