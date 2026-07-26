import Testing
import Foundation
import SwiftData
@testable import Overture

// #1426: Dan can stop watching a source from the end-of-scout popup, where the source is already named
// in front of him, instead of closing the popup and hunting for the same row in the Sources sheet.
//
// The part that needs testing is not the removal (WatchlistMutations.stopWatching already owns it, with
// its banner and its Undo, pinned in StopWatchingIsReversibleTests). It is that the popup stays HONEST
// afterwards. The failure list it draws is a SNAPSHOT of the run, frozen when the scout finished, so a
// removal cannot change it: without this filter the removed source would keep its card, and the
// "N sources couldn't be checked" heading would keep counting a source no longer being watched. Same for
// the footer: a source Dan fixed and then removed must not still be queued to be read.
@MainActor
@Suite("The scout summary stays honest after a removal (#1426)")
struct ScoutSummaryStopWatchingTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func source(_ id: String, _ org: String, in ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: org,
                              listingsURL: "https://\(id).example/events", kind: .html)
        ctx.insert(s)
        return s
    }

    private func failed(_ id: String, _ org: String) -> ScoutService.SourceResult {
        ScoutService.SourceResult(sourceId: id, orgName: org,
                                  state: .failed(.verdict(.noDatedContent)),
                                  listingsURL: "https://\(id).example/events")
    }

    // The whole point: stop watching one of the failing sources, and its card goes.
    @Test func aRemovedSourceDropsOutOfTheFailingList() throws {
        let ctx = try context()
        let protestra = source("protestra", "Protestra", in: ctx)
        let neos = source("neofuturists", "New York Neo-Futurists", in: ctx)
        try ctx.save()
        let results = [failed("protestra", "Protestra"), failed("neofuturists", "New York Neo-Futurists")]

        WatchlistMutations.stopWatching(protestra, context: ctx, feedback: ActionFeedback())

        let shown = ScoutSummaryRow.stillWorthShowing(results, in: [protestra, neos])
        #expect(shown.map(\.sourceId) == ["neofuturists"])
    }

    // And the heading counts what is actually on screen. A card that is gone but still counted is the
    // same lie in a different place.
    @Test func theHeadingCountsOnlyTheSourcesStillShown() throws {
        let ctx = try context()
        let protestra = source("protestra", "Protestra", in: ctx)
        let neos = source("neofuturists", "New York Neo-Futurists", in: ctx)
        try ctx.save()
        let results = [failed("protestra", "Protestra"), failed("neofuturists", "New York Neo-Futurists")]
        #expect(ScoutSummaryCopy.failuresHeading(results.count) == "2 sources couldn't be checked.")

        WatchlistMutations.stopWatching(protestra, context: ctx, feedback: ActionFeedback())

        let shown = ScoutSummaryRow.stillWorthShowing(results, in: [protestra, neos])
        #expect(ScoutSummaryCopy.failuresHeading(shown.count) == "One source couldn't be checked.")
    }

    // The Undo on the removal banner puts the card back. The filter reads the LIVE source, so this has to
    // fall out of resuming rather than needing its own restore path; if it did not, an undo would say it
    // worked while the popup went on showing the source as gone.
    @Test func undoingTheRemovalBringsTheCardBack() throws {
        let ctx = try context()
        let protestra = source("protestra", "Protestra", in: ctx)
        try ctx.save()
        let results = [failed("protestra", "Protestra")]
        let feedback = ActionFeedback()

        WatchlistMutations.stopWatching(protestra, context: ctx, feedback: feedback)
        #expect(ScoutSummaryRow.stillWorthShowing(results, in: [protestra]).isEmpty)

        try #require(feedback.action).perform()

        #expect(ScoutSummaryRow.stillWorthShowing(results, in: [protestra]).map(\.sourceId) == ["protestra"])
    }

    // A result with no live watchlist row of its own is not a removal, and must not vanish: an unmatched
    // result is exactly the case #1125 kept the snapshot for. Dropping it would silently swallow a
    // failure nobody could then act on.
    @Test func aResultWithNoLiveSourceIsStillShown() throws {
        let results = [failed("orphan", "An org we no longer have a row for")]
        #expect(ScoutSummaryRow.stillWorthShowing(results, in: []).map(\.sourceId) == ["orphan"])
    }

    // A source that went inactive for the OTHER reason (the org asked not to be contacted) is also gone
    // from the watchlist, so its card goes too. The popup asks "is this still watched", not "did Dan
    // remove it": both answers mean the same thing on this screen.
    @Test func aSourceThatAskedToStopAlsoDropsOut() throws {
        let ctx = try context()
        let s = source("refused", "An org that asked us to stop", in: ctx)
        s.isActive = false
        s.inactiveReason = .orgRefusal
        try ctx.save()

        #expect(ScoutSummaryRow.stillWorthShowing([failed("refused", "An org that asked us to stop")],
                                             in: [s]).isEmpty)
    }

    // MARK: - The footer

    // Fix a source's address, then decide you don't want it after all. "Read the one I fixed" must not
    // still offer to spend a scout run on a source that is no longer watched.
    @Test func aFixedThenRemovedSourceIsNoLongerQueuedToBeRead() throws {
        let ctx = try context()
        let cell = source("cell", "The Cell Theatre", in: ctx)
        let bargemusic = source("bargemusic", "Bargemusic", in: ctx)
        try ctx.save()
        let fixed: Set<String> = ["cell", "bargemusic"]

        WatchlistMutations.stopWatching(cell, context: ctx, feedback: ActionFeedback())

        #expect(ScoutSummaryRow.stillWorthShowing(fixed, in: [cell, bargemusic]) == ["bargemusic"])
    }

    // MARK: - Where the control is offered

    // The control is opt-in, and the Sources sheet does not opt in: it already has its own Stop watching
    // button on every active row, so a component that offered one by default would put two identical
    // buttons on the same row. Off by default is what keeps this one component serving both surfaces.
    @Test func theSourcesSheetDoesNotGetASecondStopWatchingButton() {
        #expect(SourceFixConfirmActions(source: WatchedSource(sourceId: "x", orgName: "X",
                                                              listingsURL: "https://x.example", kind: .html),
                                        failure: nil).offersStopWatching == false)
    }

    // Both surfaces say it in the same words, from one constant, so the sheet and the popup cannot drift
    // into calling one action two things.
    @Test func bothSurfacesNameTheActionFromOnePlace() {
        #expect(SourceFixConfirmCopy.stopWatchingTitle == "Stop watching")
        #expect(SourceGuardHelper.source("Overture/UI/SourcesView.swift")
            .contains("SourceFixConfirmCopy.stopWatchingTitle"))
        #expect(SourceGuardHelper.source("Overture/UI/ScoutSummaryView.swift")
            .contains("offersStopWatching: true"))
    }
}
