import Testing
import Foundation
import SwiftData

// #2765, phase 4 of #2620. The one genuine domain conflict between the two runs: a draft written against
// a contact a check is midway through replacing. Dan's call, 2026-08-15: exclude the overlapping SHOWS
// from the second run and say so, never refuse the whole run.
//
// Dan's call, 2026-08-20: whichever run starts SECOND yields, in both directions. No kind-based priority.
// Protecting a draft by writing it anyway is exactly the conflict, so the draft is what waits.
//
// Two refusals are new here, and both are the fail-CLOSED direction:
//
//   * every show in the run is already held, so there is nothing left to do;
//   * the other slot is LIVE and what it holds cannot be established, so nothing may safely be taken.
//
// The second is `RunCoverage.unreadable` reaching a launch. Treating it as "holds nothing" would be
// fail-open on the one control that stops two paid runs colliding (L42, L105).
//
// The subtraction happens on the SELECTION, before the queue is built, which matters on the check side:
// a check item is a REPRESENTATIVE chosen by `buildProbeQueue` standing for N shows through
// `alsoAnswersFor`. Subtracting from the built queue would either drop the whole item, silently costing
// the other N-1 shows their coverage, or keep it and violate the exclusion for the held show (L66, L166).
// Subtracting first re-plans over what is left.
@MainActor
@Suite("Shows a live run holds are excluded from the next one (#2765)")
struct HeldShowsAreExcludedTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, OrgReachabilityAnswer.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func dir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "held-2765-\(UUID().uuidString)")!
    }

    private func makeLive(_ slot: RunSlot, in support: URL) throws {
        try Data().write(to: slot.markerURL(in: support))
    }

    // MARK: - What the other run holds

    @Test func nothingIsHeldWhenTheOtherSlotIsIdle() throws {
        let d = dir()
        #expect(try PrepQueueService.heldByOtherRun(slot: .prep, now: Date(), support: d).isEmpty)
    }

    @Test func aLiveOtherRunsShowsAreHeld() throws {
        let d = dir()
        try RunCoverage.write(keys: ["a", "b"], slot: .check, in: d)
        try makeLive(.check, in: d)
        #expect(try PrepQueueService.heldByOtherRun(slot: .prep, now: Date(), support: d) == ["a", "b"])
    }

    // A leftover covers file from a run that ENDED holds nothing, or last night's run silently keeps its
    // shows for ever and the refusal names a run that finished yesterday (L121, L68).
    @Test func aFinishedRunHoldsNothing() throws {
        let d = dir()
        try RunCoverage.write(keys: ["a"], slot: .check, in: d)
        // No marker: the run ended and the runner removed it.
        #expect(try PrepQueueService.heldByOtherRun(slot: .prep, now: Date(), support: d).isEmpty)
    }

    // THE FAIL-CLOSED CASE. A live slot whose coverage cannot be read must stop the launch, not wave it
    // through: an empty answer arrives exactly when the thing has gone wrong (L98).
    @Test func aLiveRunWhoseHoldingsCannotBeReadRefusesTheLaunch() throws {
        let d = dir()
        try Data("not json".utf8).write(to: RunSlot.check.coversURL(in: d))
        try makeLive(.check, in: d)
        #expect(throws: PrepQueueService.PrepLaunchError.self) {
            _ = try PrepQueueService.heldByOtherRun(slot: .prep, now: Date(), support: d)
        }
    }

    // MARK: - The decision itself

    // Exercised HERE rather than through a launch, and the reason is not convenience. The exclusion
    // between the two runs is still in force until #3015, so `runInFlightRefusal` refuses either launch
    // the moment the other slot is live, which is the only state in which this decision does anything. A
    // launch-level test would be refused before reaching it. #3015 is where the end-to-end path becomes
    // testable, and it carries those tests (L3: built is not wired, and this says which half is which).

    @Test func nothingHeldMeansNothingDropped() {
        let sel = PrepQueueService.selection(from: ["a", "b"], excluding: [])
        #expect(sel.kept == ["a", "b"])
        #expect(sel.dropped.isEmpty)
        #expect(!sel.isEmptyBecauseHeld)
    }

    @Test func onlyTheOverlappingShowsAreDropped() {
        let sel = PrepQueueService.selection(from: ["a", "b", "c"], excluding: ["b", "z"])
        #expect(sel.kept == ["a", "c"], "a show the other run is not on must survive")
        #expect(sel.dropped == ["b"], "and only the overlap is reported as dropped, never the other run's whole list")
    }

    // The refusal fires on "nothing left BECAUSE of the other run", never on an empty selection Dan
    // simply made: those are different facts and get different sentences (L11).
    @Test func everythingHeldIsARefusal() {
        let sel = PrepQueueService.selection(from: ["a"], excluding: ["a"])
        #expect(sel.kept.isEmpty)
        #expect(sel.isEmptyBecauseHeld)
    }

    @Test func anEmptySelectionWithNothingHeldIsNotThatRefusal() {
        let sel = PrepQueueService.selection(from: [], excluding: ["a"])
        #expect(!sel.isEmptyBecauseHeld,
                "an empty selection nobody took anything from is `nothingToPrep`, not `everyShowHeld`")
    }

    // MARK: - Both launches actually use it

    // The decision is only worth having if both launches go through it, and that is wiring rather than
    // logic, so it is guarded at the source until #3015 makes it reachable (L3).
    @Test func bothLaunchesReduceTheirSelectionBeforeBuildingAQueue() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Overture/Integration/PrepQueueService.swift")
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(!source.isEmpty, "PrepQueueService.swift could not be read, so this checked nothing (L98)")
        let lines = SwiftSource.scannableLines(in: source)

        func line(containing needle: String) -> Int? {
            lines.first { $0.code.contains(needle) }?.line
        }

        let checkReduce = line(containing: "let checkSelection = selection(from: keys,")
        let checkBuild = line(containing: "let queue = buildProbeQueue(from: context")
        #expect(checkReduce != nil && checkBuild != nil,
                "could not find the check's reduction or its queue build: one has moved")
        if let checkReduce, let checkBuild {
            #expect(checkReduce < checkBuild,
                    "the check builds its queue before removing held shows, so a grouped item is planned around a show it may not take")
        }

        let prepReduce = line(containing: "let prepSelection = selection(from: eligibleKeys,")
        let prepBuild = line(containing: "let queue = buildQueue(from: context")
        #expect(prepReduce != nil && prepBuild != nil,
                "could not find the prep's reduction or its queue build: one has moved")
        if let prepReduce, let prepBuild {
            #expect(prepReduce < prepBuild, "the prep builds its queue before removing held shows")
        }
    }

    // #2765 also moves `assignArms` BELOW the subtraction. It PERSISTS a sticky, forward-only A/B arm onto
    // every prospect it is handed, and the old refusal ran before it while this one is computed from the
    // selection, so without the move a show this run then left out would keep an arm it never earned,
    // permanently (L95).
    //
    // Guarded at the SOURCE, deliberately: `assignArms` returns immediately when no experiment is active
    // (`Experiment.swift:178`), which is the state every fixture and Dan's own store are in today, so a
    // behavioural test would pass with the lines in EITHER order, on the branch that does nothing (L101).
    @Test func theSelectionIsReducedBeforeAnyArmIsAssigned() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Overture/Integration/PrepQueueService.swift")
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(!source.isEmpty, "PrepQueueService.swift could not be read, so this checked nothing (L98)")

        let lines = SwiftSource.scannableLines(in: source)
        let subtraction = lines.first { $0.code.contains("let prepSelection = selection(from: eligibleKeys,") }
        let assign = lines.first { $0.code.contains("try ExperimentAssignment.assignArms(") }
        #expect(subtraction != nil && assign != nil,
                "could not find the subtraction or the arm assignment, so this checked nothing: one has moved")
        if let subtraction, let assign {
            #expect(subtraction.line < assign.line,
                    "arms are assigned before the held shows are removed, so a show this run leaves out keeps a sticky arm it never earned")
        }
        let assignArgs = lines.first { $0.code.contains("to: eligibleProspects(from: context, includedKeys:") }
        #expect(assignArgs?.code.contains("selectedKeys") == true,
                "arms are assigned over the unreduced selection, so an excluded show is stamped anyway")
    }
}
