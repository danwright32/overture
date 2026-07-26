import Testing
import Foundation
@testable import Overture

// #1503: Squarespace serves any page as JSON with `?format=json`, no key and no auth, and a page built on
// its EVENTS collection carries the whole upcoming schedule as data: title, start date, and the venue.
// That is the same deal #1127 took for VenueTix and OPERA America, so these sources stop costing a paid
// AI extract run.
//
// Every shape below is taken from the live probe of Dan's watchlist on 2026-07-25 (21 of 66 active
// sources are Squarespace, 7 of those are events collections), including the two details that would
// otherwise have shipped as bugs: titles and venues arrive HTML-ENCODED, and `startDate` is epoch
// MILLISECONDS.
@Suite("Squarespace events collection (#1503)")
struct SquarespaceCalendarTests {
    // Trimmed from https://www.dessoff.org/events?format=json and brooklynyouthchorus.org, keeping the
    // fields the adapter reads and the real encoding.
    static let eventsFeed = #"""
    {
      "collection": { "typeName": "events", "itemCount": 82 },
      "upcoming": [
        { "title": "Symphony in Motion: Gregg Smith, Igor Stravinsky, &amp; Margaret Bonds",
          "startDate": 1793566800721,
          "fullUrl": "/events/symphony-in-motion",
          "location": { "addressTitle": "St. Paul &amp; St. Andrew Church" } },
        { "title": "Messiah Sing",
          "startDate": 1796947200957,
          "fullUrl": "/events/messiah-sing",
          "location": { "addressTitle": "Christ &amp; Saint Stephen’s Church" } }
      ],
      "past": [ { "title": "Old One", "startDate": 1700000000000 } ]
    }
    """#

    @Test("an events collection yields its upcoming shows with title, date and venue")
    func parsesUpcoming() throws {
        let events = try SquarespaceCalendar.parseEvents(Data(Self.eventsFeed.utf8))

        #expect(events.count == 2, "only upcoming; the past list is not shows to pitch")
        #expect(events[0].venue == "St. Paul & St. Andrew Church")
        #expect(events[1].title == "Messiah Sing")
    }

    // The detail the issue did not mention, and the one that would have put "&amp;" into a pitch.
    @Test("HTML entities in the title and venue are decoded")
    func decodesEntities() throws {
        let events = try SquarespaceCalendar.parseEvents(Data(Self.eventsFeed.utf8))

        #expect(events[0].title == "Symphony in Motion: Gregg Smith, Igor Stravinsky, & Margaret Bonds")
        #expect(!events[0].title.contains("&amp;"))
        #expect(!events[0].venue!.contains("&amp;"))
    }

    // `startDate` is epoch MILLISECONDS. Reading it as seconds would date every show to 1970 and drop
    // the lot as past.
    @Test("the start date is read as epoch milliseconds, not seconds")
    func readsMilliseconds() throws {
        let events = try SquarespaceCalendar.parseEvents(Data(Self.eventsFeed.utf8))

        #expect(EasternDate.dayString(from: events[0].date) == "2026-11-01")
        #expect(events[0].date.timeIntervalSince1970 > 1_700_000_000)
    }

    // Rainer Crosett's single upcoming show publishes no venue. On a NATIVE feed that is the publisher's
    // own blank field, not a page Overture failed to read (#1472), so it must survive as a real event
    // with a nil venue rather than being dropped.
    @Test("a show the publisher left venueless is kept, with no venue")
    func keepsVenuelessRow() throws {
        let feed = #"""
        { "collection": { "typeName": "events-stacked" },
          "upcoming": [ { "title": "Recital", "startDate": 1793566800721, "location": {} } ] }
        """#

        let events = try SquarespaceCalendar.parseEvents(Data(feed.utf8))

        #expect(events.count == 1)
        #expect(events[0].venue == nil)
    }

    // Detection. 7 of Dan's 21 Squarespace sources are events collections; the other 14 report `index`
    // or `page` and MUST fall through to the existing path untouched.
    @Test("only an events collection is claimed; index and page pages are not")
    func detectsOnlyEventsCollections() {
        #expect(SquarespaceCalendar.isEventsCollection(Data(Self.eventsFeed.utf8)))

        for other in ["index", "page"] {
            let feed = #"{ "collection": { "typeName": "\#(other)" }, "items": [] }"#
            #expect(!SquarespaceCalendar.isEventsCollection(Data(feed.utf8)),
                    "\(other) is not an events collection")
        }
        // Not Squarespace at all: a plain HTML page asked for ?format=json just returns the page.
        #expect(!SquarespaceCalendar.isEventsCollection(Data("<html><body>hi</body></html>".utf8)))
    }

    // #1127's reconcile-safety rule, which matters more here than anywhere: a SHORT list reads to the
    // reconcile as "the rest were cancelled" and strikes real performances. So a body we cannot decode
    // throws rather than returning what it managed.
    @Test("a feed whose shape changed throws instead of returning a short list")
    func shapeChangeThrows() {
        let drifted = #"{ "collection": { "typeName": "events" }, "upcoming": "not-a-list" }"#

        #expect(throws: SourceFetchError.feedShapeChanged) {
            try SquarespaceCalendar.parseEvents(Data(drifted.utf8))
        }
    }

    // A row missing the fields that identify a show is a shape change too, not one row to skip quietly.
    @Test("an undated row throws rather than being silently dropped")
    func undatedRowThrows() {
        let missingDate = #"""
        { "collection": { "typeName": "events" },
          "upcoming": [ { "title": "No date here", "location": { "addressTitle": "V" } } ] }
        """#

        #expect(throws: SourceFetchError.feedShapeChanged) {
            try SquarespaceCalendar.parseEvents(Data(missingDate.utf8))
        }
    }

    // Attribution. Unlike VenueTix, which is a single-VENUE feed where every show is at that venue, this
    // is an ORG's own events page: the org PRESENTS and the venue comes from the data, and it varies per
    // show. Brooklyn Youth Chorus sings at Geffen Hall and at Carnegie, and saying the venue is
    // "Brooklyn Youth Chorus" would put the wrong place in every pitch.
    @Test("the org presents, and each show keeps the venue the feed names")
    func attributesOrgAsPresenterAndKeepsPerShowVenue() throws {
        let events = try SquarespaceCalendar.parseEvents(Data(Self.eventsFeed.utf8))

        let extracted = SquarespaceCalendar.extractedEvents(from: events, orgName: "The Dessoff Choirs",
                                                            location: "New York, NY")

        #expect(extracted[0].presenter == "The Dessoff Choirs")
        #expect(extracted[0].venue == "St. Paul & St. Andrew Church")
        #expect(extracted[0].venue != "The Dessoff Choirs")
        #expect(extracted[0].performanceDate == "2026-11-01")
        #expect(extracted[0].location == "New York, NY")
    }

    // A venueless row stays venueless rather than borrowing the org's name, which would be a fabricated
    // venue of exactly the kind #995 and #1498 exist to prevent.
    @Test("a venueless show is not given the org's name as its venue")
    func venuelessStaysVenueless() throws {
        let feed = #"""
        { "collection": { "typeName": "events-stacked" },
          "upcoming": [ { "title": "Recital", "startDate": 1793566800721 } ] }
        """#
        let events = try SquarespaceCalendar.parseEvents(Data(feed.utf8))

        let extracted = SquarespaceCalendar.extractedEvents(from: events, orgName: "Rainer Crosett",
                                                            location: nil)

        #expect(extracted[0].venue == nil)
    }

    // The cheap pre-filter, so no request is ever spent probing a page that is obviously not
    // Squarespace. Checked against the LIVE pages 2026-07-25: the literal comment "This is Squarespace"
    // is present in the raw download but sits inside an HTML COMMENT, so it does NOT survive the
    // normalization Overture applies before hashing. `squarespace.com` does (it is in the image URLs),
    // which is why the marker is that and not the more obvious one.
    @Test("the pre-filter survives the page normalization Overture applies")
    func preFilterUsesAMarkerThatSurvivesNormalization() {
        // What a normalized Squarespace page still carries.
        #expect(SquarespaceCalendar.looksLikeSquarespace(
            #"<img src="https://images.squarespace-cdn.com/x.jpg"><a href="https://static1.squarespace.com/y">"#))
        // The comment-only marker is gone by then, so relying on it alone would find nothing.
        #expect(!SquarespaceCalendar.looksLikeSquarespace("<html><body>Concerts</body></html>"))
    }

    // A generous pre-filter is deliberate and safe: a page that merely MENTIONS Squarespace costs one
    // extra request and is then rejected by the events-collection check, so it can never take a source
    // off the paid read it needs.
    @Test("a page that merely mentions Squarespace is caught by the collection check, not the filter")
    func aFalsePositiveIsRejectedByTheCollectionCheck() {
        let blogPost = "<p>We moved our site to squarespace.com last year</p>"
        #expect(SquarespaceCalendar.looksLikeSquarespace(blogPost))
        // ...and the JSON view of an ordinary page is not an events collection, so nothing is promoted.
        #expect(!SquarespaceCalendar.isEventsCollection(Data(#"{"collection":{"typeName":"page"}}"#.utf8)))
    }

    // The promotion decision that takes a source off the paid read. Every "no" branch matters more than
    // the "yes": a wrong promotion silently stops a source being read properly.
    @Test("a source is promoted only when it is an html page that really is an events collection")
    func promotesOnlyARealEventsCollection() {
        let squarespacePage = #"<img src="https://images.squarespace-cdn.com/x.jpg">"#
        let eventsJSON = Data(Self.eventsFeed.utf8)

        #expect(SquarespaceCalendar.shouldPromote(kind: .html, pageHTML: squarespacePage,
                                                  jsonBody: eventsJSON))

        // Already native: nothing to promote, and re-deciding it could only do harm.
        for kind in [SourceKind.algolia, .operaAmericaFeed, .venueTixFeed, .ovationTixFeed, .squarespaceFeed] {
            #expect(!SquarespaceCalendar.shouldPromote(kind: kind, pageHTML: squarespacePage,
                                                       jsonBody: eventsJSON))
        }
        // Squarespace, but one of the 14 that are NOT events collections.
        #expect(!SquarespaceCalendar.shouldPromote(
            kind: .html, pageHTML: squarespacePage,
            jsonBody: Data(#"{"collection":{"typeName":"page"}}"#.utf8)))
        // Not Squarespace at all.
        #expect(!SquarespaceCalendar.shouldPromote(kind: .html, pageHTML: "<html>concerts</html>",
                                                   jsonBody: eventsJSON))
    }

    // The failure path, which decides what happens on a bad night for the network. A probe that did not
    // come back must leave the source exactly where it is, still being read the way that works, rather
    // than being promoted or demoted on no evidence.
    @Test("a probe that failed leaves the source alone")
    func aFailedProbeChangesNothing() {
        #expect(!SquarespaceCalendar.shouldPromote(
            kind: .html, pageHTML: #"<img src="https://images.squarespace-cdn.com/x.jpg">"#,
            jsonBody: nil))
    }

    // An events collection with nothing coming up is a real, complete answer (3 of Dan's 7 are in this
    // state today), not a failure and not a shape change.
    @Test("an events collection with nothing upcoming returns no events and does not throw")
    func emptyUpcomingIsFine() throws {
        let feed = #"{ "collection": { "typeName": "events-stacked" }, "upcoming": [], "past": [] }"#

        #expect(try SquarespaceCalendar.parseEvents(Data(feed.utf8)).isEmpty)
    }
}
