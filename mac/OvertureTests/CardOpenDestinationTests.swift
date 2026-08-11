import Testing
import Foundation

// #1643: where a click on the card's own area goes. A rule, not a rendering detail, so it lives on the
// model where a test can reach it, and it is DERIVED from the same reference links the card's visible
// link is drawn from: the row and the link cannot promise two different pages.
@Suite("Where a click on the whole card goes (#1643)")
struct CardOpenDestinationTests {
    private func item(listing: String?, website: String? = nil) -> QueueItem {
        QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                  performanceDate: "2026-09-12", sourceListingURL: listing, websiteURL: website,
                  priorRelationship: "none", production: "self", profile: "strong",
                  coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                  matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new)
    }

    @Test func theCardOpensItsListing() {
        let url = QueueModel.cardOpenDestination(item(listing: "https://example.org/shows/aurora"))
        #expect(url?.absoluteString == "https://example.org/shows/aurora")
    }

    // It is the SAME URL the visible link opens, read from the same place, so a change to one is a
    // change to both.
    @Test func itIsTheSameUrlTheVisibleListingLinkOpens() {
        let i = item(listing: "https://example.org/shows/aurora")
        #expect(QueueModel.cardOpenDestination(i) == QueueModel.rowReferenceLinks(i).listing)
    }

    // No listing, no destination: the card carries no whole-row target rather than one that does nothing.
    @Test func aCardWithNoListingHasNoDestination() {
        #expect(QueueModel.cardOpenDestination(item(listing: nil)) == nil)
    }

    // The group website is a different promise (the act's own site, not this performance), and it is the
    // link Dan did not click. A card with only a website keeps that link and gains no row target, rather
    // than sending a click on the card's empty space somewhere he never asked to go.
    @Test func aWebsiteAloneIsNotTheCardsDestination() {
        #expect(QueueModel.cardOpenDestination(item(listing: nil,
                                                    website: "https://aurorastrings.example")) == nil)
    }

    // An unusable stored value is no destination, exactly as it is no link: the card cannot open a page
    // it cannot address.
    @Test func aBlankListingIsNoDestination() {
        #expect(QueueModel.cardOpenDestination(item(listing: "   ")) == nil)
    }

    // The action a screen reader announces names the page the card actually opens, in the words the card
    // already uses for it (#1680), so the two can never describe different destinations.
    @Test func theSpokenActionNamesTheLinkTheCardShows() {
        #expect(CardOpenCopy.accessibilityLabel(show: "Aurora Strings", linkLabel: "Source listing")
                == "Open the source listing for Aurora Strings")
        #expect(CardOpenCopy.accessibilityLabel(show: "Aurora Strings", linkLabel: "Venue calendar")
                == "Open the venue calendar for Aurora Strings")
    }
}
