import Testing
import Foundation

// The last wire (#1500), which no test above it can see. Every rule in BulkDismissTests and
// BulkDismissMutationTests stays green if the date header never offers the action, offers it on the wrong
// stage, or skips the confirm and dismisses the night on the click. That is the #887 lesson, and the same
// shape as DismissDayOffWiringGuardTests.
//
// Pins the WIRING only, never the words: the sentences belong to BulkDismiss and ActionAck and are
// asserted there. Pinning copy in a source guard is what #1451 had to undo.
@Suite("Whole-night dismiss wiring (#1500)")
struct BulkDismissWiringGuardTests {
    private func source(_ rel: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(rel, file: file)
    }

    @Test func theDateHeaderOffersTheActionOnARightClick() {
        let queue = source("Overture/UI/QueueView.swift")
        #expect(!queue.isEmpty)
        #expect(queue.contains(".contextMenu { if focusedStage == .scout { nightDismissMenu(group) } }"))
    }

    // Dan's call (2026-07-26): Scout only. A night of shows already kept, drafted or approved must not be
    // reachable by one right-click, so the stage check is part of the wiring, not a styling detail.
    @Test func theActionIsScoutOnly() {
        let queue = source("Overture/UI/QueueView.swift")
        #expect(queue.contains("if focusedStage == .scout"))
    }

    // The menu offers only the half that is possible for a night of untriaged shows: the seven endings for
    // a show nothing was sent to. Never allCases, which would put `wentBy` and `tooFar` (Overture's own
    // automatic cuts, #864/#1238) and the five pitched endings in front of Dan, and applying any of them by
    // hand to a whole night would record something he never said.
    @Test func theMenuOffersOnlyTheEndingsANightOfUntriagedShowsCanReach() {
        let queue = source("Overture/UI/QueueView.swift")
        #expect(queue.contains("ForEach(ShowOutcome.neverPitched"))
        #expect(!queue.contains("ForEach(ShowOutcome.allCases"))
        #expect(!queue.contains("ForEach(ShowOutcome.danCanChoose"))
    }

    // Picking a reason must RAISE the confirm, never dismiss on the spot. The confirm is where the count
    // is stated, which is the issue's own requirement: no silent burying of rows Dan cannot see.
    @Test func pickingAReasonRaisesTheConfirmRatherThanDismissingImmediately() {
        let queue = source("Overture/UI/QueueView.swift")
        #expect(queue.contains("pendingNightDismiss = NightDismiss("))
        #expect(queue.contains(".sheet(item: $pendingNightDismiss)"))
        // A first-party branded sheet, not a stock system dialog (#1249, and Dan's standing preference).
        #expect(queue.contains("SelfBookingConfirmSheet("))
        // The dismissal itself happens on the sheet's own buttons, and nowhere else in this view. Which
        // shows each button takes is pinned separately, below.
        #expect(queue.contains("onProceed: { dismissNight(pending,"))
    }

    // The action goes through the one mutation that records a single undo entry for the night. A view that
    // looped a per-card dismiss would give Dan five presses of Cmd+Z to get one night back, which is the
    // thing the issue asked not to happen.
    @Test func theConfirmGoesThroughTheOneBatchMutation() {
        let queue = source("Overture/UI/QueueView.swift")
        #expect(queue.contains("ProspectMutations.dismissAll("))
        #expect(queue.contains("undo: undoStack"))
    }

    // Dan's follow-up (2026-07-26): the second button must dismiss the NARROWER set. Both buttons call the
    // same mutation, so the only thing separating "clear the night" from "leave the runs alone" is which
    // key set each one passes. Swapping them is invisible on screen until dates start disappearing.
    @Test func eachButtonPassesItsOwnSetOfShows() {
        let queue = source("Overture/UI/QueueView.swift")
        #expect(queue.contains("onAlternative: pending.offersChoice"))
        #expect(queue.contains("dismissNight(pending, keys: pending.keysOnlyThisNight)"))
        #expect(queue.contains("onProceed: { dismissNight(pending, keys: pending.keys)"))
    }

    // And the narrower way out is offered only when the night actually holds both kinds. A sheet offering
    // "dismiss only the 0" would be a button that does nothing.
    @Test func theNarrowerButtonIsOnlyOfferedWhenThereIsAChoice() {
        let queue = source("Overture/UI/QueueView.swift")
        #expect(queue.contains("alternativeLabel: pending.offersChoice"))
    }

    // And the undo the App performs resolves EVERY row of the entry, not just the first. Resolving one
    // would restore one show of five and report the night as back.
    @Test func theUndoResolvesEveryRowInTheEntry() {
        let root = source("Overture/App/RootView.swift")
        #expect(!root.isEmpty)
        #expect(root.contains("QueueUndo.apply(entry, resolving:"))
    }
}
