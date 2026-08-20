import Testing
import Foundation

// #3012. The stop control must NAME the run it will actually stop.
//
// Found by the red-team on #2765's plan-lite, 2026-08-20. Today the two halves come from different
// places and can disagree:
//
//   * the LABEL is `PrepQueueService.runInFlight(now:)`, which returns ONE `RunKind?` and asks the prep
//     slot first. `RunKind.of` returns `.prep` only when the marker's start is more than
//     `sameRunTolerance` BEFORE the run's own start, so a check started after a live prep resolves to
//     `.reachabilityCheck`;
//   * the ACTION is `cancelPrep()`, which targets `takeover.presented`, and that is
//     `RunTakeover.order.first`, the run that started FIRST.
//
// So with a prep running and a check started after it, the button reads "Cancel reachability check" and
// cancels the PREP. Dan kills a live drafting run believing he stopped a contact check, and the check
// carries on spending. Latent only while the exclusion holds; #3015 is what makes it reachable.
//
// The fix is not a second lookup that agrees, it is ONE source: the label is asked OF THE SLOT the button
// will cancel. A per-slot query also keeps #2614's wording correct for the upgrade window, where a check
// started by a build older than #2760 sits in the PREP slot and must still be called a reachability
// check rather than a prep run.
@MainActor
@Suite("Cancel names the run it stops (#3012)")
struct CancelNamesWhatItStopsTests {

    private func dir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "cancel-3012-\(UUID().uuidString)")!
    }

    private func makeLive(_ slot: RunSlot, in support: URL) throws {
        try Data().write(to: slot.markerURL(in: support))
    }

    // MARK: - The per-slot question

    @Test func aLiveCheckSlotIsAlwaysAReachabilityCheck() throws {
        let d = dir()
        try makeLive(.check, in: d)
        #expect(PrepQueueService.runInFlight(slot: .check, now: Date(), support: d,
                                             defaults: freshDefaults()) == .reachabilityCheck)
    }

    @Test func aLivePrepSlotIsAPrepRun() throws {
        let d = dir()
        let defaults = freshDefaults()
        try makeLive(.prep, in: d)
        PrepQueueService.recordRunStarted(slot: .prep, at: Date(), defaults: defaults)
        #expect(PrepQueueService.runInFlight(slot: .prep, now: Date(), support: d,
                                             defaults: defaults) == .prep)
    }

    @Test func aSlotThatIsNotRunningAnswersNothing() throws {
        let d = dir()
        #expect(PrepQueueService.runInFlight(slot: .prep, now: Date(), support: d,
                                             defaults: freshDefaults()) == nil)
        #expect(PrepQueueService.runInFlight(slot: .check, now: Date(), support: d,
                                             defaults: freshDefaults()) == nil)
    }

    // THE CASE THE WHOLE ISSUE IS ABOUT. Both slots live, the check having started second. Asked per
    // slot, each answers for itself, so a control aimed at the prep slot can never be labelled with the
    // check's name.
    @Test func withBothRunsLiveEachSlotStillAnswersForItself() throws {
        let d = dir()
        let defaults = freshDefaults()
        let started = Date()
        try makeLive(.prep, in: d)
        PrepQueueService.recordRunStarted(slot: .prep, at: started, defaults: defaults)
        try makeLive(.check, in: d)
        PrepQueueService.recordRunStarted(slot: .check, at: started.addingTimeInterval(30), defaults: defaults)

        #expect(PrepQueueService.runInFlight(slot: .prep, now: Date(), support: d, defaults: defaults) == .prep,
                "the prep slot must still read as a prep run, or a control aimed at it is labelled with the other run's name")
        #expect(PrepQueueService.runInFlight(slot: .check, now: Date(), support: d, defaults: defaults) == .reachabilityCheck)
    }

    // The whole-app question is the one that CANNOT express two, and that is now stated rather than
    // discovered. It is kept for the readers that legitimately ask "is anything going", and #2761 is what
    // replaces the ones that need to describe both.
    @Test func theWholeAppQuestionAnswersForOneRunOnly() throws {
        let d = dir()
        let defaults = freshDefaults()
        let started = Date()
        try makeLive(.prep, in: d)
        PrepQueueService.recordRunStarted(slot: .prep, at: started, defaults: defaults)
        try makeLive(.check, in: d)
        PrepQueueService.recordRunStarted(slot: .check, at: started.addingTimeInterval(30), defaults: defaults)

        let one = PrepQueueService.runInFlight(now: Date(), support: d, defaults: defaults)
        #expect(one != nil, "with two runs live it must still answer that something is going")
        // Deliberately NOT asserting WHICH: that is the ambiguity #2761 removes, and pinning it here
        // would freeze an answer nobody chose (L103).
    }

    // MARK: - The control and its label come from ONE slot

    // The view's own wiring, which cannot be unit-tested (a SwiftUI body is not reachable from here), so
    // it is guarded at the source. The defect is not that the two lookups disagree in some case, it is
    // that there are TWO: any fix that leaves the label and the action reading different sources can
    // drift apart again.
    @Test func theCancelButtonsLabelAndActionComeFromTheSameSlot() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Overture/App/RootView.swift")
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(!source.isEmpty, "RootView.swift could not be read, so this checked nothing (L98)")

        let lines = SwiftSource.scannableLines(in: source)
        guard let button = lines.first(where: { $0.code.contains("cancelLabel") }) else {
            Issue.record("could not find the Cancel button's label, so this checked nothing: it has moved")
            return
        }
        // The binding that decides whether the button EXISTS must be the slot the action targets. Anything
        // else is a second source of truth, which is the defect.
        let above = lines.filter { $0.line < button.line && $0.line > button.line - 6 }
        let bindsToTheTakeover = above.contains { $0.code.contains("takeover.presented") }
        #expect(bindsToTheTakeover,
                """
                the Cancel button is not bound to `takeover.presented`, which is what `cancelPrep()` \
                actually cancels. Its label therefore comes from a different lookup than its action, and \
                with both runs live the two disagree: the button names one run and stops the other.
                """)
        #expect(!button.code.contains("PrepQueueService.runInFlight(now:"),
                "the label still reads the whole-app question, which cannot say which of two live runs the action will hit")
    }
}
