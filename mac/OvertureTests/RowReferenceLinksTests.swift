import Testing
import Foundation

// LIVE-STORE-CLAIM verified=2026-07-28 measure="untriaged rows carrying neither a source listing URL nor a group website"
// #1600 Phase 7.2 / #1534: the row's reference strip. With both of the status lines that used to sit in
// here retired, the strip can now be completely empty, which on the live store is 145 untriaged rows
// carrying neither a source listing nor a group website. An empty padded strip is a gap in the card with
// nothing in it, so the emptiness has to be decided somewhere a test can see it.
@Suite("The row's reference strip (#1600)")
struct RowReferenceLinksTests {

    // #1825: the two arrays are separate arguments because they are separate facts. `sourceCalendars` is
    // the watched source's own calendar address (what the label keys on); `runURLs` is every member
    // night's own event page (what FeedReconcile keys on). Conflating them is the defect this suite now
    // guards, so a test cannot set one and accidentally mean the other.
    private func item(listing: String? = nil, website: String? = nil,
                      status: ReviewStatus = .new,
                      sourceCalendars: [String] = [], runURLs: [String] = []) -> QueueItem {
        var built = builtItem(listing: listing, website: website, status: status)
        built.sourceCalendarURLs = sourceCalendars
        built.runSourceURLs = runURLs
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
    // #1825: both rows now carry the same POPULATED source calendar, so the two verdicts differ only on
    // the row's own link. Before, the "Source listing" half could pass simply because the field it read
    // was empty, which is a verdict on nothing.
    @Test func aListingThatIsJustTheSourcesOwnCalendarIsLabelledAsOne() {
        let perEvent = item(listing: "https://thegreenroom42.venuetix.com/showdetails/s1/a1",
                            sourceCalendars: ["https://thegreenroom42.venuetix.com/"])
        let calendarOnly = item(listing: "https://thegreenroom42.venuetix.com/",
                                sourceCalendars: ["https://thegreenroom42.venuetix.com/"])

        #expect(QueueModel.listingLinkLabel(perEvent) == "Source listing")
        #expect(QueueModel.listingLinkLabel(calendarOnly) == "Venue calendar")
    }

    // #1825: a row whose link really IS the source's whole listings page, spelled as the live store spells
    // it. Chain Theatre publishes its season on one page, so every show there falls back to it.
    @Test func arealCalendarFallbackFromTheLiveStoreStillReadsAsACalendar() {
        let onePageSeason = item(listing: "https://www.chaintheatre.org/whats-on",
                                 sourceCalendars: ["https://www.chaintheatre.org/whats-on"])
        #expect(QueueModel.listingLinkLabel(onePageSeason) == "Venue calendar")
    }

    // #1825: the same claim as the test above, but fed by the PIPELINE instead of a hand-written array.
    // `RunGrouping` fills runSourceURLs by compactMapping the members' OWN listing URLs, so a row is
    // always inside its own run's URLs and the old comparison matched on every row. The fixture above
    // hand-set the source's calendar URL, a shape RunGrouping cannot emit, so it passed forever while
    // the label was inverted on 692 of the live store's 702 rows (LESSONS L48).
    //
    // Two real Carnegie nights, spelled as the live store spells them.
    @Test func aPerEventListingFromARealRunIsNotCalledAVenueCalendar() throws {
        let nights = [
            RunGrouping.RunRow(
                id: 1, groupName: "Orchestra of St. Luke's", venue: "Carnegie Hall",
                performanceDate: "2026-06-23",
                sourceListingURL: "https://www.carnegiehall.org/calendar/2026/06/23/orchestra-of-st-lukes-0700pm"),
            RunGrouping.RunRow(
                id: 2, groupName: "Orchestra of St. Luke's", venue: "Carnegie Hall",
                performanceDate: "2026-06-24",
                sourceListingURL: "https://www.carnegiehall.org/calendar/2026/06/24/orchestra-of-st-lukes-0700pm"),
        ]
        let run = try #require(RunGrouping.group(nights).first)
        // Non-vacuous: the source's calendar is present and populated, so "Source listing" is a real
        // verdict about this link rather than the answer an empty field always gives.
        let built = item(listing: run.row.sourceListingURL,
                         sourceCalendars: ["https://www.carnegiehall.org/calendar"],
                         runURLs: run.runSourceURLs)
        #expect(run.runSourceURLs.contains(run.row.sourceListingURL ?? ""),
                "the run really does carry the row's own URL, which is what the old rule matched on")
        #expect(QueueModel.listingLinkLabel(built) == "Source listing")
    }

    // A trailing slash is not a different page. Without this the fallback link, which is the source URL
    // verbatim, would read as a per-event link the moment the two spellings differed by one character.
    @Test func theCalendarComparisonIgnoresATrailingSlash() {
        let calendarOnly = item(listing: "https://ci.ovationtix.com/35583",
                                sourceCalendars: ["https://ci.ovationtix.com/35583/"])
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

// #1825: the label is only as good as the data it is handed. `sourceCalendarURLs` defaults to empty, and
// an empty one makes every row read "Source listing", which is the same class of silent wrongness as the
// bug being fixed, just pointing the other way. A correct rule that no surface feeds is not a fix (L3),
// and neither the rule's own tests nor the live-store guards can see this: they never build a view.
@Suite("The listing link label is actually fed by both card surfaces (#1825)")
struct ListingLinkLabelWiringTests {

    @Test func theQueueBuilderResolvesEachRowsSourceCalendars() {
        let model = SourceGuardHelper.source("Overture/UI/QueueView+Model.swift")
        // #2524: found by NAME rather than by the signature's last line. Pinned to the closing line it
        // broke the moment a parameter was added after `now:`, and a marker that stops matching returns
        // nil, which every `contains` below is quietly false against (#2192). The name is the thing this
        // guard is actually about.
        guard let body = SourceGuardHelper.bodyOfFunction(named: "items", in: model) else {
            Issue.record("QueueModel.items(from:) is gone, so this guard is asking nothing")
            return
        }
        #expect(body.contains("item.sourceCalendarURLs"))
        // Resolved through the row's OWN sources, not "any watched source", so a row can never inherit a
        // calendar address from a source it was never found on.
        #expect(body.contains("sourceIds.compactMap"))
    }

    @Test func bothCardSurfacesPassTheWatchlistIn() {
        for path in ["Overture/UI/QueueView.swift", "Overture/UI/ArchiveView.swift"] {
            let source = SourceGuardHelper.source(path)
            guard let body = SourceGuardHelper.propertyBody("private var items: [QueueItem] {", in: source)
            else {
                Issue.record("\(path) no longer builds its rows through a `private var items: [QueueItem]`")
                continue
            }
            #expect(body.contains("sources: watchedSources"),
                    "\(path) builds cards without the watchlist, so every link would read as a per-event page")
            #expect(source.contains("@Query private var watchedSources: [WatchedSource]"),
                    "\(path) has no live watchlist query to pass")
        }
    }
}
