import Testing
import Foundation
@testable import Overture

// #1600 Phase 7.2: the row's reference strip. With "Contact: keep to prep" retired, the strip can now be
// completely empty, which on the live store is 145 untriaged rows carrying neither a source listing nor
// a group website. An empty padded strip is a gap in the card with nothing in it, so the emptiness has
// to be decided somewhere a test can see it.
@Suite("The row's reference strip (#1600)")
struct RowReferenceLinksTests {

    private func item(listing: String? = nil, website: String? = nil,
                      status: ReviewStatus = .new, hasDraft: Bool = false) -> QueueItem {
        var i = QueueItem(id: "k", groupName: "An Evening of Song", discipline: "music",
                          venue: "A Hall", performanceDate: "2026-09-12",
                          sourceListingURL: listing, websiteURL: website,
                          priorRelationship: "none", production: "unclear", profile: "unknown",
                          coverage: "unknown", fitScore: 5, tier: "mid", fitReason: "",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: status)
        if hasDraft { i.draftBody = "Hello there." }
        return i
    }

    @Test func anUntriagedShowWithNeitherLinkShowsNoStripAtAll() {
        let bare = item()
        #expect(QueueModel.rowHasReferenceLinks(bare) == false)
        #expect(QueueModel.rowReferenceLinks(bare).note == nil)
    }

    @Test func aKeptShowStillSaysPrepWillPickItUp() {
        let kept = item(status: .queued)
        #expect(QueueModel.rowReferenceLinks(kept).note == "Contact: pending Prep run")
        #expect(QueueModel.rowHasReferenceLinks(kept))
    }

    @Test func aLinkAloneIsEnoughToDrawTheStrip() {
        #expect(QueueModel.rowHasReferenceLinks(item(listing: "https://example.org/show")))
        #expect(QueueModel.rowHasReferenceLinks(item(website: "https://example.org")))
    }

    // A stored empty string is not a link, and neither is something no URL can be made of. Either one
    // would otherwise draw a strip with an invisible member in it.
    @Test func ablankOrUnusableURLIsNotALink() {
        #expect(QueueModel.rowReferenceLinks(item(listing: "")).listing == nil)
        #expect(QueueModel.rowReferenceLinks(item(listing: "   ")).listing == nil)
        #expect(QueueModel.rowHasReferenceLinks(item(listing: "")) == false)
    }

    // Once a draft exists, the Prep claim is spent: the run it promised has happened.
    @Test func aDraftedShowDropsThePrepClaim() {
        let drafted = item(status: .drafted, hasDraft: true)
        #expect(QueueModel.rowReferenceLinks(drafted).note == nil)
    }
}
