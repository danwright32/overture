import Testing
import Foundation
import SwiftData
@testable import Overture

// #1450: Carnegie's row was excluded from EVERY per-source action, on both surfaces. The exclusion was
// written for Fix (its listings URL is a display-only placeholder over a POST search API, so there is no
// address to correct) but it also took away the only exit.
//
// That matters because #802 rests on a failing source NEVER auto-deactivating: Dan removing it himself is
// the deliberate escape hatch, and #842 already established that an escape hatch he cannot see is not one.
// A native feed that started failing would be reported at him every run with nothing he could press.
//
// The rule moves onto the component instead of being re-stated at each call site: a source with no
// editable page offers no Fix and no Confirm, whatever its failure says, and that is now the ONLY thing
// its kind decides. Stopping is offered to every source.
@MainActor
@Suite("A native-feed source can be stopped too (#1450)")
struct NativeFeedEscapeHatchTests {

    // MARK: - What the kind may decide

    // Carnegie's URL is a placeholder nothing may fetch, so offering to correct it would be offering to
    // edit a field that does nothing. Asserted against failures that DO offer Fix on any ordinary source,
    // so this is the kind winning, not the failure declining.
    @Test func aPlaceholderAddressIsNeverOfferedForCorrection() {
        #expect(!SourceFixConfirmActions.offersFix(.fetch(.unreachable), kind: .algolia))
        #expect(!SourceFixConfirmActions.offersFix(.verdict(.noDatedContent), kind: .algolia))
        #expect(!SourceFixConfirmActions.offersFix(nil, kind: .algolia))
    }

    // Same for Confirm: "this page is right" anchors to the bytes last read from a page, and there is no
    // page here.
    @Test func aFeedWithNoPageIsNeverAskedToConfirmOne() {
        #expect(!SourceFixConfirmActions.offersConfirm(.verdict(.noDatedContent), kind: .algolia))
    }

    // The rule must stay narrow. The other native feeds are host-routed: they ingest for free like
    // Carnegie, but they are watched at a REAL URL that can be wrong, so Fix has to survive for them.
    // Applying this to "ingests natively" instead of "has no editable page" would silently take the
    // address control off three working sources.
    @Test func theOtherNativeFeedsKeepTheirAddressControl() {
        for kind in [SourceKind.venueTixFeed, .ovationTixFeed, .operaAmericaFeed, .html] {
            #expect(SourceFixConfirmActions.offersFix(.fetch(.unreachable), kind: kind),
                    "\(kind) is watched at a real URL, which can be the wrong one")
        }
        #expect(SourceFixConfirmActions.offersConfirm(.verdict(.noDatedContent), kind: .html))
    }

    // With the kind rule moved onto the component, the Sources sheet stops gating the component at its
    // call site, so the component itself has to draw NOTHING for a source it has nothing to offer, rather
    // than an empty row of controls under Carnegie.
    @Test func aSourceWithNothingOnOfferDrawsNoControls() {
        #expect(!SourceFixConfirmActions.offersAnything(failure: .fetch(.unreachable), kind: .algolia,
                                                        stopWatching: false))
        #expect(SourceFixConfirmActions.offersAnything(failure: .fetch(.unreachable), kind: .algolia,
                                                       stopWatching: true))
        #expect(SourceFixConfirmActions.offersAnything(failure: nil, kind: .html, stopWatching: false))
    }

    // MARK: - The exit itself

    // The escape hatch has to be real, not just visible: stopping the feed must actually stop it being
    // scouted. The plan filters on isActive before it picks the native sources, so this is what makes the
    // button's promise true rather than cosmetic.
    @Test func stoppingANativeFeedTakesItOutOfTheNextRun() throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self, WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let carnegie = WatchedSource(sourceId: WatchedSource.carnegieId, orgName: "Carnegie Hall",
                                     listingsURL: WatchedSourceBackfill.carnegieListingsURL, kind: .algolia)
        ctx.insert(carnegie)
        try ctx.save()
        let before = SourceSchedule.plan(sources: [carnegie], depth: .watchOnly, now: Date())
        #expect(before.native.map(\.sourceId) == [WatchedSource.carnegieId])

        WatchlistMutations.stopWatching(carnegie, context: ctx, feedback: ActionFeedback())

        let after = SourceSchedule.plan(sources: [carnegie], depth: .watchOnly, now: Date())
        #expect(after.native.isEmpty, "a stopped feed must not be swept anyway")
    }

    // And it is the same reversible stop every other source gets, so the row, its tuned feed-health
    // history and the source id stamped on every prospect it ever surfaced all survive, and the Sources
    // sheet's Watch again (which is gated on the grade, not the kind) brings it back.
    @Test func stoppingANativeFeedIsTheSameReversibleStop() throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self, WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let carnegie = WatchedSource(sourceId: WatchedSource.carnegieId, orgName: "Carnegie Hall",
                                     listingsURL: WatchedSourceBackfill.carnegieListingsURL, kind: .algolia)
        carnegie.baselineFeedCount = 42
        ctx.insert(carnegie)
        try ctx.save()
        let feedback = ActionFeedback()

        WatchlistMutations.stopWatching(carnegie, context: ctx, feedback: feedback)

        #expect(SourceGrade(carnegie) == .removed, "the grade that draws Watch again")
        #expect(carnegie.baselineFeedCount == 42, "its tuned self-heal history must survive")
        try #require(feedback.action).perform()
        #expect(carnegie.isActive)
    }

    // MARK: - The wiring

    // Neither surface may re-impose the old blanket exclusion at its call site: the popup used to gate the
    // whole action block on the kind, which is what hid the exit in the first place.
    @Test func neitherSurfaceGatesItsActionsOnTheKindAnyMore() {
        #expect(!SourceGuardHelper.source("Overture/UI/ScoutSummaryView.swift").contains("!= .algolia"))
        #expect(!SourceGuardHelper.source("Overture/UI/SourcesView.swift")
            .contains("source.isActive, source.kind != .algolia"))
    }
}
