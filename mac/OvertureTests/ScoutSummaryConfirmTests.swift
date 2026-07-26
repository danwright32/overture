import Testing
import Foundation
import SwiftData
@testable import Overture

// #1499: Dan pressed "This page is right" on the Scout results screen, the banner said it was marked, and
// the card went on showing the rust failure line the press was supposed to settle. The confirm DID work on
// the data; the CARD is a snapshot of the run, frozen when the scout finished, so it kept saying what was
// true a minute ago.
//
// That is the "did that work?" failure mode. Dan's only evidence a press landed is a banner that
// disappears, sitting above a card still stating the problem, so the honest reading from outside is that
// the button is broken and the next move is to press it again or to go and fix an address that was fine.
//
// His call (2026-07-25): the card VANISHES once confirmed, and the "N sources couldn't be checked" count
// drops by one, exactly as it does when a source is stopped from this screen (#1426). One rule on the
// screen rather than two.
//
// This is the THIRD button on this card to need the same treatment (#1125 the address, #1426 stop
// watching), so the rule is now stated once as "does the live row still have anything to say", rather than
// enumerated per action and patched again the next time a button is added.
@MainActor
@Suite("The scout summary stays honest after a confirm (#1499)")
struct ScoutSummaryConfirmTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func source(_ id: String, _ org: String, in ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: org,
                              listingsURL: "https://\(id).example/events", kind: .html)
        s.lastContentHash = "read-bytes"       // it was read, so a confirm has bytes to anchor to
        s.health = .failing
        s.lastFailure = .verdict(.noDatedContent)
        ctx.insert(s)
        return s
    }

    private func failed(_ id: String, _ org: String) -> ScoutService.SourceResult {
        ScoutService.SourceResult(sourceId: id, orgName: org,
                                  state: .failed(.verdict(.noDatedContent)),
                                  listingsURL: "https://\(id).example/events")
    }

    // THE case, exactly as Dan hit it: confirm The Unsung Collective's page and its card goes.
    @Test func aConfirmedPageDropsOutOfTheFailingList() throws {
        let ctx = try context()
        let unsung = source("unsung", "The Unsung Collective", in: ctx)
        let other = source("protestra", "Protestra", in: ctx)
        try ctx.save()
        let results = [failed("unsung", "The Unsung Collective"), failed("protestra", "Protestra")]

        #expect(WatchlistEditing.confirmEmpty(unsung, in: ctx) == .confirmed)

        #expect(ScoutSummaryRow.stillWorthShowing(results, in: [unsung, other]).map(\.sourceId)
                == ["protestra"])
    }

    // And the heading counts what is actually on screen. A card that is gone but still counted is the same
    // dishonesty in a different place.
    @Test func theCouldntBeCheckedCountDropsByOne() throws {
        let ctx = try context()
        let unsung = source("unsung", "The Unsung Collective", in: ctx)
        let other = source("protestra", "Protestra", in: ctx)
        try ctx.save()
        let results = [failed("unsung", "The Unsung Collective"), failed("protestra", "Protestra")]

        #expect(ScoutSummaryRow.stillWorthShowing(results, in: [unsung, other]).count == 2)
        _ = WatchlistEditing.confirmEmpty(unsung, in: ctx)
        #expect(ScoutSummaryRow.stillWorthShowing(results, in: [unsung, other]).count == 1)
    }

    // A confirm on a source with no bytes to anchor to still clears the failure (confirmEmpty returns
    // .noHash but has already set health and cleared lastFailure), so the card must go for that path too.
    // Keying the rule to the ANSWER (does it still report a problem) rather than to confirmedEmptyHash is
    // what covers this: the hash is not always written, but the settled health always is.
    @Test func aConfirmWithNoBytesToAnchorToStillClearsTheCard() throws {
        let ctx = try context()
        let unsung = source("unsung", "The Unsung Collective", in: ctx)
        unsung.lastContentHash = nil
        unsung.pendingContentHash = nil
        try ctx.save()

        #expect(WatchlistEditing.confirmEmpty(unsung, in: ctx) == .noHash)

        #expect(ScoutSummaryRow.stillWorthShowing([failed("unsung", "The Unsung Collective")],
                                                  in: [unsung]).isEmpty)
    }

    // THE regression this could plausibly cause, and the reason the rule is not simply "has no failure".
    // Correcting an address ALSO clears lastFailure, but it leaves health at .neverChecked, because the
    // source has not been checked at the new address yet. That card must STAY: #1125 exists so Dan can see
    // his correction on it, and the footer's "Read the ones I fixed" needs it. Not-yet-checked is not
    // settled, it is unknown.
    @Test func aCorrectedAddressKeepsItsCardBecauseNothingIsSettledYet() throws {
        let ctx = try context()
        let unsung = source("unsung", "The Unsung Collective", in: ctx)
        try ctx.save()

        #expect(WatchlistEditing.editURL(unsung, to: "https://theunsungcollective.org/concert-season",
                                         in: ctx) == .saved(sourceId: "unsung"))

        #expect(unsung.lastFailure == nil)               // the failure was cleared...
        #expect(unsung.health == .neverChecked)          // ...but nothing has been verified yet
        #expect(ScoutSummaryRow.stillWorthShowing([failed("unsung", "The Unsung Collective")],
                                                  in: [unsung]).map(\.sourceId) == ["unsung"])
    }

    // A source Dan confirmed must not still be queued for a paid re-read by "Read the ones I fixed": there
    // is nothing left to find out about it. Same rule, asked of the fixed ids.
    @Test func aConfirmedSourceIsNotOfferedForARead() throws {
        let ctx = try context()
        let unsung = source("unsung", "The Unsung Collective", in: ctx)
        let other = source("protestra", "Protestra", in: ctx)
        try ctx.save()

        _ = WatchlistEditing.confirmEmpty(unsung, in: ctx)

        #expect(ScoutSummaryRow.stillWorthShowing(["unsung", "protestra"], in: [unsung, other])
                == ["protestra"])
    }

    // Unchanged from #1426, re-asserted here because the rule that decides it now has a second reason to
    // drop a card and must not have lost the first: a result with no live row at all STAYS. That is the
    // unmatched case #1125 kept the snapshot for, and dropping it would silently swallow a failure.
    @Test func aResultWithNoLiveRowStillStays() throws {
        #expect(ScoutSummaryRow.stillWorthShowing([failed("orphan", "Orphan")], in: [])
                .map(\.sourceId) == ["orphan"])
    }
}
