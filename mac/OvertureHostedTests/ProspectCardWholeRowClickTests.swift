import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #1643, Dan on 2026-07-28: "I should be able to click anywhere on the row, not just on the text."
// The card is the surface he triages on, and the only thing a click on it could reach was the listing
// LINK, a few characters wide at the bottom of the left column. Everything else (the empty space beside
// the title, the padding around the fit score, the blank right-hand column) did nothing at all.
//
// So the card's own area now opens the same page that link opens. Rendered rather than asserted from the
// source, because the whole question is whether the target is really ON the row and whether the row's own
// controls still answer for themselves: logic in a SwiftUI view is untestable unless it is exercised.
@MainActor
@Suite("The whole queue card is the click target (#1643)")
struct ProspectCardWholeRowClickTests {
    // A box rather than a captured var: the closure outlives the statement that makes it, and this
    // records every open, so a test can say a click opened the listing ONCE and not twice.
    private final class Opened {
        var urls: [String] = []
    }

    private let listing = "https://example.org/shows/aurora-strings"

    private func contact(_ email: String) -> RecipientSnapshot {
        RecipientSnapshot(id: email, name: nil, email: email, role: nil, provenance: .act,
                          sendState: .pending, replied: false, lastReplyText: nil, resolution: nil,
                          bounced: false, outcomeSource: nil)
    }

    private func item(listing: String?, contacts: [RecipientSnapshot] = []) -> QueueItem {
        var i = QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music",
                          venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                          sourceListingURL: listing, websiteURL: nil, priorRelationship: "none",
                          production: "self", profile: "strong", coverage: "likely_uncovered",
                          fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                          possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        i.contacts = contacts
        return i
    }

    private func card(_ item: QueueItem, opened: Opened,
                      onKeep: @escaping () -> Void = {}) -> ProspectRowView {
        ProspectRowView(item: item, today: "2026-09-01", onKeep: onKeep, onDismiss: { _ in },
                        openCardLink: { opened.urls.append($0.absoluteString) })
    }

    // The whole point: a click on the row's own area, nowhere near any text, opens the show's listing.
    @Test func aClickOnTheCardsOwnAreaOpensTheShowsListing() throws {
        let opened = Opened()
        let view = card(item(listing: listing), opened: opened)

        try view.inspect().find(ViewType.HStack.self).callOnTapGesture()

        #expect(opened.urls == [listing])
    }

    // The row target is a gesture ON the row, not a Button wrapped AROUND it. That distinction is the
    // whole of requirement two: a Button around the card's contents takes every click inside it, so Keep,
    // Dismiss and the pills would stop being their own targets the moment the row became one.
    @Test func theRowCarriesTheTargetItselfRatherThanWrappingItsControlsInAButton() throws {
        let opened = Opened()
        var kept = false
        let view = card(item(listing: listing), opened: opened, onKeep: { kept = true })

        // The row that holds Keep is an HStack carrying a tap gesture, so nothing is nested inside a
        // control that would swallow the ones drawn on it.
        try view.inspect().find(ViewType.HStack.self).callOnTapGesture()
        #expect(opened.urls == [listing])

        try view.inspect().find(button: "Keep").tap()
        #expect(kept, "Keep must still keep")
        #expect(opened.urls == [listing], "Keep must not also open the listing")
    }

    // The selectable address line, called out in the issue: a click there is Dan reaching for the
    // address, not for the show's page, so the address takes its own click.
    @Test func aClickOnAContactAddressDoesNotOpenTheListing() throws {
        let opened = Opened()
        let view = card(item(listing: listing, contacts: [contact("anna@example.org")]), opened: opened)

        try view.inspect().find(text: "anna@example.org").callOnTapGesture()

        #expect(opened.urls.isEmpty)
    }

    // A card with no listing has nothing to open, so it carries no row target at all. A click that
    // silently does nothing is the state this issue exists to end; it must not be reintroduced as the
    // row's own behaviour on the cards that have no page to go to.
    @Test func aCardWithNoListingCarriesNoRowTarget() throws {
        let opened = Opened()
        let view = card(item(listing: nil), opened: opened)

        #expect(throws: (any Error).self) {
            try view.inspect().find(ViewType.HStack.self).callOnTapGesture()
        }
        #expect(opened.urls.isEmpty)
    }

    // The link the row target agrees with is still drawn on the card, at rest, saying where the card
    // goes. It is the whole of this control's visible affordance and the way anyone not using a mouse
    // reaches the same page, so losing it would leave the enlarged target undiscoverable and unreachable
    // while every other test here still passed.
    @Test func theListingLinkTheRowTargetAgreesWithIsStillOnTheCard() throws {
        let opened = Opened()
        let view = card(item(listing: listing), opened: opened)

        let destinations = try view.inspect().findAll(ViewType.Link.self).map { try $0.url().absoluteString }

        #expect(destinations.contains(listing))
    }

    // The half of the accessibility work a rendered test cannot reach: ViewInspector refuses to read
    // accessibility ACTIONS on this OS ("currently unavailable for inspection"), so what the card
    // announces is pinned in CardOpenDestinationTests, and that it is ATTACHED to the row in
    // ProspectRowCardOpenGuardTests: the same split #1742 landed on for the genre control's label.
}
