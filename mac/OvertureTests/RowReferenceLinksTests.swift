import Testing
import Foundation
@testable import Overture

// LIVE-STORE-CLAIM verified=2026-07-28 measure="untriaged rows carrying neither a source listing URL nor a group website"
// #1600 Phase 7.2 / #1534: the row's reference strip. With both of the status lines that used to sit in
// here retired, the strip can now be completely empty, which on the live store is 145 untriaged rows
// carrying neither a source listing nor a group website. An empty padded strip is a gap in the card with
// nothing in it, so the emptiness has to be decided somewhere a test can see it.
@Suite("The row's reference strip (#1600)")
struct RowReferenceLinksTests {

    private func item(listing: String? = nil, website: String? = nil,
                      status: ReviewStatus = .new, sources: [String] = []) -> QueueItem {
        var built = builtItem(listing: listing, website: website, status: status)
        built.runSourceURLs = sources
        return built
    }

    private func builtItem(listing: String?, website: String?, status: ReviewStatus) -> QueueItem {
        QueueItem(id: "k", groupName: "An Evening of Song", discipline: "music",
                  venue: "A Hall", performanceDate: "2026-09-12",
                  sourceListingURL: listing, websiteURL: website,
                  priorRelationship: "none", production: "unclear", profile: "unknown",
                  coverage: "unknown", fitScore: 5, tier: "mid", fitReason: "",
                  matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                  status: status)
    }

    @Test func anUntriagedShowWithNeitherLinkShowsNoStripAtAll() {
        #expect(QueueModel.rowHasReferenceLinks(item()) == false)
    }

    // #1680, Dan's call (2026-07-28): a row that could not produce a per-event link falls back to the
    // source's own calendar rather than to nothing, and the card says which kind of link it is, so he knows
    // before clicking whether it takes him to the show or just to the venue's listings. A link labelled as
    // the show's page that lands on a calendar of forty other shows is worse than an honest calendar link.
    @Test func aListingThatIsJustTheSourcesOwnCalendarIsLabelledAsOne() {
        let perEvent = item(listing: "https://thegreenroom42.venuetix.com/showdetails/s1/a1",
                            sources: ["https://thegreenroom42.venuetix.com/"])
        let calendarOnly = item(listing: "https://thegreenroom42.venuetix.com/",
                                sources: ["https://thegreenroom42.venuetix.com/"])

        #expect(QueueModel.listingLinkLabel(perEvent) == "Source listing")
        #expect(QueueModel.listingLinkLabel(calendarOnly) == "Venue calendar")
    }

    // A trailing slash is not a different page. Without this the fallback link, which is the source URL
    // verbatim, would read as a per-event link the moment the two spellings differed by one character.
    @Test func theCalendarComparisonIgnoresATrailingSlash() {
        let calendarOnly = item(listing: "https://ci.ovationtix.com/35583",
                                sources: ["https://ci.ovationtix.com/35583/"])
        #expect(QueueModel.listingLinkLabel(calendarOnly) == "Venue calendar")
    }

    // A row from the AI read path names the page it was actually read from, which is not the source's own
    // listings URL, so it keeps the ordinary label.
    @Test func aRowWithNoRecordedSourceUrlsStillReadsAsAnEventPage() {
        #expect(QueueModel.listingLinkLabel(item(listing: "https://org.example/events/night")) == "Source listing")
    }

    // #1534: the strip carries LINKS and nothing else. A kept show used to add "Contact: pending Prep
    // run" here, which drew a strip on a card that has no links to show. Two things were wrong with it.
    // It was a status claim keyed on isKept, while the thing that actually decides whether Prep will
    // pick a show up is PrepQueueBuilder.needsPrepEligible, so it went on promising a Prep run for a
    // show Prep refuses over an open date conflict. And a kept, undrafted show is only ever visible
    // inside the Prep stage list, whose heading already says these are the shows waiting for a Prep
    // run, so the line restated the heading above it on every row.
    @Test func aKeptShowWithNoLinksDrawsNoStripAtAll() {
        #expect(QueueModel.rowHasReferenceLinks(item(status: .queued)) == false)
    }

    // Being kept changes nothing about the strip: same card, same two links, decided the same way.
    @Test func keepingAShowDoesNotChangeWhatTheStripHolds() {
        let listing = "https://example.org/show"
        let untriaged = QueueModel.rowReferenceLinks(item(listing: listing))
        let kept = QueueModel.rowReferenceLinks(item(listing: listing, status: .queued))
        #expect(untriaged.listing == kept.listing)
        #expect(untriaged.website == kept.website)
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
}
