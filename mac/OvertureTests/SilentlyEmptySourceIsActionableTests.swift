import Testing
import Foundation
import SwiftData

// #2207. The scout summary rendered the silently-empty-feed warning through `infoBlock`, whose comment
// read "An informational section: one sentence Dan reads, nothing to act on". But the sentence names the
// source on purpose: #1531 added the name on the grounds that it is "the only actionable fact in the
// warning". So the copy was written to be acted on and the surface was built to say there was nothing to
// do, and there was no Fix, no Confirm, and no route to the source in Sources.
//
// A source in the failures section gets both controls inline plus "Read the ones I fixed". A source that
// returned zero after previously listing shows got a sentence and a Done button, and that is the case
// that most needs looking at: it is the shape of a page whose format changed, and it is invisible
// everywhere else because nothing failed.
//
// Observed 2026-08-06 with The Players Theatre. Dan: "what exactly am I supposed to do with this."
@MainActor
@Suite("A source that went quiet can be acted on (#2207)")
struct SilentlyEmptySourceIsActionableTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([WatchedSource.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func source(_ ctx: ModelContext, _ id: String = "players") -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: "The Players Theatre",
                              listingsURL: "https://theplayerstheatre.example/shows", kind: .html)
        // A silently empty source read FINE. That is the whole difficulty: on the row it is
        // indistinguishable from a source with nothing on this week.
        s.health = .ok
        s.lastCheckedAt = Date(timeIntervalSince1970: 1_700_000_000)
        ctx.insert(s)
        return s
    }

    private func result(_ id: String = "players") -> ScoutService.SourceResult {
        ScoutService.SourceResult(sourceId: id, orgName: "The Players Theatre", state: .ingested(found: 0),
                                  listingsURL: "https://theplayerstheatre.example/shows")
    }

    // A quiet source stays on screen while there is still something to do about it. Read through the
    // failures rule it would vanish the instant it was drawn, because that rule asks the live row whether
    // it reports a problem and this row reports none: nothing failed, which is the whole difficulty.
    @Test func aquietSourceStaysOnScreenWhileThereIsSomethingToDo() throws {
        let ctx = ModelContext(try container())
        let s = source(ctx)

        #expect(ScoutSummaryRow.silentlyEmptyStillWorthShowing([result()], in: [s]).count == 1)
        #expect(ScoutSummaryRow.stillWorthShowing([result()], in: [s]).isEmpty,
                "the premise: the failures rule cannot answer for this row, so it has its own")
    }

    // Confirming the page settles it, and the card goes.
    @Test func sayingThePageIsRightSettlesIt() throws {
        let ctx = ModelContext(try container())
        let s = source(ctx)
        s.confirmedEmptyHash = "abc123"

        #expect(ScoutSummaryRow.silentlyEmptyStillWorthShowing([result()], in: [s]).isEmpty)
    }

    // So does stopping watching it.
    @Test func stoppingWatchingSettlesItToo() throws {
        let ctx = ModelContext(try container())
        let s = source(ctx)
        s.isActive = false

        #expect(ScoutSummaryRow.silentlyEmptyStillWorthShowing([result()], in: [s]).isEmpty)
    }

    // A CORRECTED address deliberately does not. The new address has not been read yet, so the card has to
    // stay: it is what "Read the ones I fixed" is about, and it is where Dan sees his correction landed.
    @Test func acorrectedAddressLeavesTheCardThereToBeRead() throws {
        let ctx = ModelContext(try container())
        let s = source(ctx)
        s.listingsURL = "https://theplayerstheatre.example/whats-on"

        #expect(ScoutSummaryRow.silentlyEmptyStillWorthShowing([result()], in: [s]).count == 1)
    }

    // A result with no live row at all stays, the same rule the failures follow: that is not a removal,
    // and dropping it would silently swallow the warning.
    @Test func aresultWithNoLiveRowIsNotSilentlyDropped() {
        #expect(ScoutSummaryRow.silentlyEmptyStillWorthShowing([result()], in: []).count == 1)
    }

    // MARK: - the controls

    // Confirm is what this case needs and is what it never had: "yes, this page is right, it is just
    // quiet". There is no failure recorded, because nothing failed, so it cannot come from one.
    @Test func aquietPageOffersTheConfirmThatSettlesIt() {
        #expect(SourceFixConfirmActions.offersConfirm(nil, kind: .html) == false,
                "the premise: with no failure there is nothing for the ordinary rule to offer")
        #expect(SourceFixConfirmActions.offersConfirm(nil, kind: .html, readFineAndCameBackEmpty: true))
    }

    // And Fix, because a page whose format changed is exactly as likely to have moved.
    @Test func aquietPageOffersTheAddressFixToo() {
        #expect(SourceFixConfirmActions.offersFix(nil, kind: .html))
        #expect(SourceFixConfirmActions.offersAnything(failure: nil, kind: .html, stopWatching: true,
                                                       readFineAndCameBackEmpty: true))
    }

    // A source with no editable page still offers neither, whatever it came back with. Carnegie is watched
    // at a display-only placeholder over a POST search API: "Change the page link" would edit a field nothing
    // reads and "This page is right" would confirm a page that does not exist (#1450).
    @Test func asourceWithNoEditablePageStillOffersNeither() {
        #expect(SourceFixConfirmActions.offersConfirm(nil, kind: .algolia, readFineAndCameBackEmpty: true)
                == false)
        #expect(SourceFixConfirmActions.offersFix(nil, kind: .algolia) == false)
        // It can still be stopped, which is the exit #1450 restored.
        #expect(SourceFixConfirmActions.offersAnything(failure: nil, kind: .algolia, stopWatching: true,
                                                       readFineAndCameBackEmpty: true))
    }

    // The heading says what happened rather than that something failed, because nothing did.
    @Test func theheadingSaysWhatHappened() {
        #expect(ScoutSummaryCopy.silentlyEmptyHeading(1) == "One source went quiet.")
        #expect(ScoutSummaryCopy.silentlyEmptyHeading(3) == "3 sources went quiet.")
        #expect(!ScoutSummaryCopy.silentlyEmptyHeading(1).contains("couldn't"))
    }
}

// The wiring: the section is drawn as a card with controls, not as a sentence with nothing to do.
@Suite("The quiet-source section carries its controls (#2207)")
struct SilentlyEmptySectionGuardTests {
    private var source: String { SourceGuardHelper.source("Overture/UI/ScoutSummaryView.swift") }

    @Test func thequietSectionIsNoLongerAnInformationalBlock() throws {
        let section = try #require(SourceGuardHelper.bodyOfFunction(named: "sectionView", in: source))
        // The case renders the card, not the one-sentence block whose whole comment says there is
        // nothing to act on.
        #expect(section.contains("silentlyEmptyBlock(stillEmpty)"))
        #expect(!section.contains("infoBlock(ScoutWarningCopy.silentlyEmptyFeed"))
    }

    @Test func eachQuietRowCarriesFixConfirmAndStopWatching() throws {
        let row = try #require(SourceGuardHelper.bodyOfFunction(named: "silentlyEmptyRow", in: source))
        #expect(row.contains("SourceFixConfirmActions("))
        #expect(row.contains("offersStopWatching: true"))
        #expect(row.contains("readFineAndCameBackEmpty: true"))
        // Fixing one queues it for the same "Read the ones I fixed" run a failure's fix does.
        #expect(row.contains("onFixed: { fixedIds.insert($0) }"))
    }

    // The subtitle promises "I'll read the ones you fix", and it is shown only when there is something to
    // act on. A run whose only card is a quiet source must show it, or the promise goes missing from the
    // one screen offering the fix.
    @Test func thesubtitleAppearsForAQuietSourceToo() throws {
        let gate = try #require(SourceGuardHelper.propertyBody(
            "private var hasActionableFailures: Bool {", in: source))
        #expect(gate.contains("silentlyEmptyStillWorthShowing"))
    }
}
