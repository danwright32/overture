import Testing
import Foundation

// #1344: SoHo Playhouse (ci.ovationtix.com/35583) is an OvationTix (AudienceView) single-page app; a plain
// fetch reads as a 2.4 KB shell with no events, so the source went down the paid AI-read path. Its calendar
// actually loads from a public JSON feed the SPA calls, `GET web.ovationtix.com/trs/api/rest/
// CalendarProductions`, scoped to the venue by a `clientId` REQUEST HEADER (the numeric id in the venue's
// own URL path). The response is a date-keyed array: each day carries the productions playing that day.
// Reading it is deterministic and hashable, so unlike a browser render it is safe for the reconcile.
// These tests pin the parse of a REAL feed slice (captured live 2026-07-22 from client 35583) and the rules.
@Suite("OvationTix calendar feed adapter")
struct OvationTixCalendarTests {
    // A real slice of SoHo Playhouse's CalendarProductions feed (client 35583), trimmed to the fields the
    // adapter reads. "Hungry Women" plays all three days (a real multi-night run); the last day carries a
    // genuinely hidden production the public calendar suppresses.
    // #1680: `showtimes` is real and always present; it was trimmed out of this fixture originally because
    // nothing read it. It is what addresses ONE NIGHT of a run: the feed repeats a production under each of
    // its dates and gives that date's own performanceId (verified against the live feed, 2026-07-28).
    static let feed = #"""
    [
      {"date":"2026-07-23","productions":[
        {"productionId":1280419,"name":"Hungry Women","supertitle":"","subtitle":"","hidden":false,
         "showtimes":[{"productionId":1280419,"performanceId":11817828,"performanceStartTime":"2026-07-23 19:00"}]},
        {"productionId":1281174,"name":"The Passion of Mr. Cardboard","supertitle":"","subtitle":"","hidden":false,
         "showtimes":[{"productionId":1281174,"performanceId":11817900,"performanceStartTime":"2026-07-23 21:00"}]},
        {"productionId":1277321,"name":"Live From The Afterlife","supertitle":"","subtitle":"","hidden":false,
         "showtimes":[{"productionId":1277321,"performanceId":11817950,"performanceStartTime":"2026-07-23 20:00"}]}
      ]},
      {"date":"2026-07-24","productions":[
        {"productionId":1280419,"name":"Hungry Women","supertitle":"","subtitle":"","hidden":false,
         "showtimes":[{"productionId":1280419,"performanceId":11817821,"performanceStartTime":"2026-07-24 19:00"}]},
        {"productionId":1276943,"name":"Wisard","supertitle":"","subtitle":"","hidden":false,
         "showtimes":[{"productionId":1276943,"performanceId":11817960,"performanceStartTime":"2026-07-24 19:30"}]}
      ]},
      {"date":"2026-07-25","productions":[
        {"productionId":1280419,"name":"Hungry Women","supertitle":"","subtitle":"","hidden":false,
         "showtimes":[{"productionId":1280419,"performanceId":11817822,"performanceStartTime":"2026-07-25 19:00"}]},
        {"productionId":1283185,"name":"Jena Friedman: Late Show","supertitle":"","subtitle":"","hidden":true,
         "showtimes":[{"productionId":1283185,"performanceId":11817999,"performanceStartTime":"2026-07-25 23:00"}]}
      ]}
    ]
    """#

    private static func day(_ iso: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)!
    }

    @Test func parsesTheDateKeyedFeedIntoDatedEvents() throws {
        let events = try OvationTixCalendar.parseEvents(Data(Self.feed.utf8))
        // Six visible (productionId, date) rows; the hidden one is excluded (see its own test).
        #expect(events.count == 6)
        let hungry = events.filter { $0.title == "Hungry Women" }
        #expect(hungry.count == 3)
        #expect(hungry.map(\.date).sorted() == [Self.day("2026-07-23"), Self.day("2026-07-24"), Self.day("2026-07-25")])
        #expect(events.contains { $0.title == "The Passion of Mr. Cardboard" && $0.date == Self.day("2026-07-23") })
    }

    // A production flagged hidden is suppressed on the public calendar, so it is not a pitchable listing and
    // is dropped. The visible productions on that same day are unaffected.
    @Test func excludesHiddenProductions() throws {
        let events = try OvationTixCalendar.parseEvents(Data(Self.feed.utf8))
        #expect(!events.contains { $0.title == "Jena Friedman: Late Show" })
    }

    // Each production's date IS the group's date, and every night of a run carries the same productionId, so
    // the multi-night collapse can key on the feed's own id rather than on date proximity.
    @Test func carriesTheProductionIdAsSeriesId() throws {
        let events = try OvationTixCalendar.parseEvents(Data(Self.feed.utf8))
        let hungry = events.filter { $0.title == "Hungry Women" }
        #expect(hungry.allSatisfy { $0.seriesId == "1280419" })
    }

    // super/subtitle are captured when the feed carries them, and read as nil (never "") when empty, so an
    // empty marketing line never pollutes the synthesized document or the extracted identity.
    @Test func capturesSuperAndSubtitleWhenPresentAndNilWhenEmpty() throws {
        let withTitles = #"""
        [{"date":"2026-09-01","productions":[
          {"productionId":42,"name":"A Show","supertitle":"World Premiere","subtitle":"A new play","hidden":false}
        ]}]
        """#
        let e = try OvationTixCalendar.parseEvents(Data(withTitles.utf8))
        #expect(e.count == 1)
        #expect(e[0].superTitle == "World Premiere")
        #expect(e[0].subTitle == "A new play")
        // The real feed slice carries empty super/subtitle, which must read as nil.
        let real = try OvationTixCalendar.parseEvents(Data(Self.feed.utf8))
        #expect(real.allSatisfy { $0.superTitle == nil && $0.subTitle == nil })
    }

    // The feed dates are day-granular, so a show playing TODAY must be kept even when the run happens in the
    // afternoon; only a day that is genuinely past is dropped. Filtering a COMPLETE feed to a stable window
    // keeps the reconcile honest: a show leaves the set only once its day is past, never from a partial read.
    @Test func keepsTodayAndLaterDroppingOnlyPastDays() throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let now = today.addingTimeInterval(15 * 3600)   // 3pm today, well after midnight
        let events = [
            OvationTixCalendar.OTEvent(title: "Gone", superTitle: nil, subTitle: nil, date: yesterday),
            OvationTixCalendar.OTEvent(title: "Today", superTitle: nil, subTitle: nil, date: today),
            OvationTixCalendar.OTEvent(title: "Later", superTitle: nil, subTitle: nil, date: tomorrow),
        ]
        let kept = OvationTixCalendar.upcoming(events, now: now)
        #expect(Set(kept.map(\.title)) == ["Today", "Later"])
    }

    // #1171-style guard: an undocumented public feed will change shape eventually. A feed that answers with
    // date groups whose rows no longer parse (a renamed date value) yields zero events from a non-empty body,
    // which must fail loud rather than read as an empty calendar.
    @Test func parsingThrowsWhenTheFeedHasRowsButNoneParse() {
        // Real-shaped groups, but the date value format changed to US slashes: every row fails to date.
        let drifted = #"""
        [{"date":"07/23/2026","productions":[{"productionId":1,"name":"A Show","hidden":false}]}]
        """#
        #expect(throws: SourceFetchError.feedShapeChanged) {
            _ = try OvationTixCalendar.parseEvents(Data(drifted.utf8))
        }
    }

    // A genuinely empty feed (the venue has nothing loaded) is NOT drift: it parses to zero from zero and
    // must stay a normal quiet result, never a failure.
    @Test func parsingAnEmptyFeedIsNotTreatedAsDrift() throws {
        #expect(try OvationTixCalendar.parseEvents(Data("[]".utf8)).isEmpty)
    }

    // #1184-style: a required field drifting (here `name`) makes the decode throw a DecodingError, which
    // without this reads as the misleading "couldn't reach that page". On a non-empty body it is a format
    // change and must read the same clear way as the renamed-date guard above.
    @Test func aNonEmptyBodyMissingARequiredFieldReadsAsFormatChanged() {
        let missingName = #"[{"date":"2026-07-23","productions":[{"productionId":1,"hidden":false}]}]"#
        #expect(throws: SourceFetchError.feedShapeChanged) {
            _ = try OvationTixCalendar.parseEvents(Data(missingName.utf8))
        }
    }

    // LIVE-FEED-CLAIM verified=2026-08-02 measure="visible (production, day) rows carrying more than one showtime, both watched OvationTix venues"
    // #1984: a production can play TWICE on one day, and the adapter used to keep only the first showtime
    // (`showtimes.first`), so the second performance was discarded with nothing recording that it existed.
    // Measured live against both watched venues: 24 of 274 visible rows carry two showtimes, never more.
    // These four are verbatim from that read (SoHo Playhouse client 35583, The Players Theatre client 277).
    //
    // The show stays ONE row, because Dan pitches a production once. What must not happen is the row
    // claiming the day starts at 5:00 PM when it also has a 9:15 PM performance, which is what a card
    // showing the first time alone would say.
    static let doubleBill = #"""
    [
      {"date":"2026-08-08","productions":[
        {"productionId":9001,"name":"We've Been Here Before: A One Woman Musical","hidden":false,
         "showtimes":[{"productionId":9001,"performanceId":501,"performanceStartTime":"2026-08-08 17:00"},
                      {"productionId":9001,"performanceId":502,"performanceStartTime":"2026-08-08 21:15"}]}
      ]},
      {"date":"2026-09-27","productions":[
        {"productionId":9002,"name":"Alice in Wonderland the Musical","hidden":false,
         "showtimes":[{"productionId":9002,"performanceId":601,"performanceStartTime":"2026-09-27 11:00"},
                      {"productionId":9002,"performanceId":602,"performanceStartTime":"2026-09-27 14:00"}]}
      ]}
    ]
    """#

    // The single-performance case, which is the majority (250 of the 274 rows measured): one start time,
    // read off the feed's own `performanceStartTime` rather than assumed.
    @Test func capturesTheStartTimeOfASinglePerformanceDay() throws {
        let events = try OvationTixCalendar.parseEvents(Data(Self.feed.utf8))
        let cardboard = try #require(events.first { $0.title == "The Passion of Mr. Cardboard" })
        #expect(cardboard.startTimes == ["21:00"])
        let wisard = try #require(events.first { $0.title == "Wisard" })
        #expect(wisard.startTimes == ["19:30"])
    }

    // #1984, the defect itself: BOTH performances survive, in the order the feed lists them. Before this,
    // the 9:15 PM show did not exist as far as Overture was concerned.
    @Test func keepsBothStartTimesWhenAProductionPlaysTwiceInOneDay() throws {
        let events = try OvationTixCalendar.parseEvents(Data(Self.doubleBill.utf8))
        let musical = try #require(events.first { $0.title.hasPrefix("We've Been Here Before") })
        #expect(musical.startTimes == ["17:00", "21:15"])
        let alice = try #require(events.first { $0.title == "Alice in Wonderland the Musical" })
        #expect(alice.startTimes == ["11:00", "14:00"])
    }

    // A double bill is still ONE pitchable row, not two: Dan pitches a production once, and splitting it
    // would also break the multi-night run collapse that keys on the production id.
    @Test func aDayWithTwoPerformancesIsStillOneRow() throws {
        let events = try OvationTixCalendar.parseEvents(Data(Self.doubleBill.utf8))
        #expect(events.count == 2)
        #expect(events.filter { $0.title.hasPrefix("We've Been Here Before") }.count == 1)
    }

    // A feed that names no showtimes (or omits the field entirely) yields NO times rather than a
    // fabricated one. `showtimes` is optional throughout for exactly this reason: it may cost the time,
    // never the row.
    @Test func aProductionWithNoShowtimesCarriesNoStartTimeAndStillSurvives() throws {
        let noTimes = #"""
        [{"date":"2026-09-01","productions":[
          {"productionId":42,"name":"A Show","hidden":false},
          {"productionId":43,"name":"Another Show","hidden":false,"showtimes":[]}
        ]}]
        """#
        let events = try OvationTixCalendar.parseEvents(Data(noTimes.utf8))
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.startTimes.isEmpty })
    }

    // A showtime whose stated day disagrees with the day it is filed under is NOT quietly relabelled onto
    // this date: the two facts contradict each other, and a time is worth having only if it is this day's.
    // The row survives with the times that do agree.
    @Test func aShowtimeStatedForAnotherDayIsDroppedRatherThanRelabelled() throws {
        let mismatched = #"""
        [{"date":"2026-09-01","productions":[
          {"productionId":44,"name":"A Show","hidden":false,
           "showtimes":[{"productionId":44,"performanceId":701,"performanceStartTime":"2026-09-02 19:00"},
                        {"productionId":44,"performanceId":702,"performanceStartTime":"2026-09-01 20:00"}]}
        ]}]
        """#
        let events = try OvationTixCalendar.parseEvents(Data(mismatched.utf8))
        #expect(events.count == 1)
        #expect(events[0].startTimes == ["20:00"])
    }

    // A drifted time value costs the TIME and never the show. The row is real and pitchable whether or not
    // its clock survived the read.
    @Test func anUnparseableStartTimeCostsTheTimeNotTheShow() throws {
        let drifted = #"""
        [{"date":"2026-09-01","productions":[
          {"productionId":45,"name":"A Show","hidden":false,
           "showtimes":[{"productionId":45,"performanceId":801,"performanceStartTime":"7:00 PM"}]}
        ]}]
        """#
        let events = try OvationTixCalendar.parseEvents(Data(drifted.utf8))
        #expect(events.count == 1)
        #expect(events[0].title == "A Show")
        #expect(events[0].startTimes.isEmpty)
    }

    @Test func handlesOvationtixHostsOnly() {
        #expect(OvationTixCalendar.handles(URL(string: "https://ci.ovationtix.com/35583")!))
        #expect(OvationTixCalendar.handles(URL(string: "https://web.ovationtix.com/whatever")!))
        #expect(!OvationTixCalendar.handles(URL(string: "https://ovationtix.com.evil.com/35583")!))
        #expect(!OvationTixCalendar.handles(URL(string: "https://evilovationtix.com/35583")!))
        #expect(!OvationTixCalendar.handles(URL(string: "https://thegreenroom42.venuetix.com/")!))
    }

    // The feed is scoped to one venue by the numeric client id in the venue's URL path, so the adapter must
    // read that id out of the path and never anything else.
    @Test func readsTheClientIdFromTheUrlPath() {
        #expect(OvationTixCalendar.clientId(from: URL(string: "https://ci.ovationtix.com/35583")!) == "35583")
        #expect(OvationTixCalendar.clientId(from: URL(string: "https://ci.ovationtix.com/35583/")!) == "35583")
        #expect(OvationTixCalendar.clientId(from: URL(string: "https://ci.ovationtix.com/35583/production/1")!) == "35583")
        #expect(OvationTixCalendar.clientId(from: URL(string: "https://ci.ovationtix.com/")!) == nil)
    }

    // The feed returns 400 without the client id as a REQUEST HEADER (a query param is ignored), so the
    // adapter must send it as the `clientId` header against the fixed CalendarProductions endpoint.
    @Test func theFeedRequestCarriesTheClientIdHeader() {
        let req = OvationTixCalendar.feedRequest(clientId: "35583")
        #expect(req.url?.absoluteString == "https://web.ovationtix.com/trs/api/rest/CalendarProductions")
        #expect(req.value(forHTTPHeaderField: "clientId") == "35583")
    }

    // The synthesized document (the lead path) attributes every show to the venue by NAME (the feed carries
    // no venue name) and gives each an explicit ISO date, deterministically.
    @Test func synthesizesADocumentAttributedToTheVenue() throws {
        let events = try OvationTixCalendar.parseEvents(Data(Self.feed.utf8))
        let html = OvationTixCalendar.listingHTML(events, venueName: "SoHo Playhouse")
        for needle in ["SoHo Playhouse", "Hungry Women", "The Passion of Mr. Cardboard"] {
            #expect(html.contains(needle), "listing HTML is missing \(needle)")
        }
        #expect(OvationTixCalendar.listingHTML(events, venueName: "SoHo Playhouse") == html)  // deterministic
        #expect(!html.contains("Jena Friedman"))   // hidden never surfaces
    }

    // #1175-style: the feed carries no city, so Dan's supplied venue location is stamped into every show's
    // place line, and with none supplied the document is byte-for-byte unchanged (no content-hash churn).
    @Test func threadsTheVenueLocationWhenProvidedAndOmitsItOtherwise() throws {
        let events = try OvationTixCalendar.parseEvents(Data(Self.feed.utf8))
        let located = OvationTixCalendar.listingHTML(events, venueName: "SoHo Playhouse",
                                                     location: "15 Vandam St, New York, NY 10013")
        #expect(located.contains("15 Vandam St, New York, NY 10013"))
        let withNil = OvationTixCalendar.listingHTML(events, venueName: "SoHo Playhouse", location: nil)
        #expect(withNil == OvationTixCalendar.listingHTML(events, venueName: "SoHo Playhouse"))
    }

    // #1237-style: a production that runs more than one night in the feed carries a shared seriesId into the
    // extracted events so those nights collapse into one run; a single-night show keeps a nil id.
    @Test func extractedEventsAttributeTheVenueAndTagMultiNightRunsOnly() throws {
        let events = try OvationTixCalendar.parseEvents(Data(Self.feed.utf8))
        let extracted = OvationTixCalendar.extractedEvents(from: events, presenter: "SoHo Playhouse",
                                                           venue: "SoHo Playhouse",
                                                           location: "New York, NY")
        #expect(extracted.allSatisfy { $0.presenter == "SoHo Playhouse" && $0.venue == "SoHo Playhouse" })
        #expect(extracted.allSatisfy { $0.location == "New York, NY" })
        // Hungry Women runs three nights -> its id survives; the one-night shows carry no id.
        #expect(extracted.filter { $0.title == "Hungry Women" }.allSatisfy { $0.seriesId == "1280419" })
        #expect(extracted.filter { $0.title == "The Passion of Mr. Cardboard" }.allSatisfy { $0.seriesId == nil })
    }

    // #1984 + #1699: the times reach the EXTRACTED event, not just the parsed one. A fact captured at the
    // reader and dropped at the boundary is a field with no consumer, which is the whole defect this pair
    // exists to fix, one layer further out.
    @Test func extractedEventsCarryEveryStartTimeOfTheDay() throws {
        let events = try OvationTixCalendar.parseEvents(Data(Self.doubleBill.utf8))
        let extracted = OvationTixCalendar.extractedEvents(from: events, presenter: "The Players Theatre",
                                                           venue: "The Players Theatre",
                                                           location: "New York, NY")
        let musical = try #require(extracted.first { $0.title.hasPrefix("We've Been Here Before") })
        #expect(musical.startTimes == ["17:00", "21:15"])
        let alice = try #require(extracted.first { $0.title == "Alice in Wonderland the Musical" })
        #expect(alice.startTimes == ["11:00", "14:00"])
    }

    // A feed fetch that fails must throw, never return an empty list: an empty read would read to the
    // reconcile as "every show was cancelled" and strike real shows.
    @Test func liveEventsPathThrowsWhenTheFeedFails() async throws {
        struct FeedError: Error {}
        let url = URL(string: "https://ci.ovationtix.com/35583")!
        await #expect(throws: FeedError.self) {
            _ = try await OvationTixCalendar.fetchEvents(url: url, now: Date()) { _ in throw FeedError() }
        }
    }

    // A url with no client id in its path cannot be scoped to a venue, so the fetch throws rather than
    // silently reading nothing.
    @Test func fetchThrowsWhenTheUrlCarriesNoClientId() async throws {
        let url = URL(string: "https://ci.ovationtix.com/")!
        await #expect(throws: SourceFetchError.self) {
            _ = try await OvationTixCalendar.fetchEvents(url: url, now: Date()) { _ in Data("[]".utf8) }
        }
    }

    @Test func fetchReadsUpcomingShowsThroughToAStoredDocument() async throws {
        let url = URL(string: "https://ci.ovationtix.com/35583")!
        let before = Self.day("2026-07-01")   // before the fixture's dates
        var sawHeader: String?
        let page = try await OvationTixCalendar.fetch(url: url, venueName: "SoHo Playhouse", now: before) { req in
            sawHeader = req.value(forHTTPHeaderField: "clientId")
            return Data(Self.feed.utf8)
        }
        #expect(sawHeader == "35583")
        #expect(page.normalizedHTML.contains("Hungry Women"))
        #expect(page.normalizedHTML.contains("SoHo Playhouse"))
        #expect(page.finalURL == url.absoluteString)
        #expect(!page.contentHash.isEmpty)
    }

    // A one-off lead pointed at an ovationtix host is routed to the feed adapter (not read as the empty SPA
    // shell), and the source's name and location reach the adapter so a single-venue feed still places
    // in-region.
    @Test func sourceFetcherRoutesOvationtixUrlsAndThreadsTheNameAndLocation() async throws {
        let ot = URL(string: "https://ci.ovationtix.com/35583")!
        let stub = FetchedPage(normalizedHTML: "OT-STUB", finalURL: ot.absoluteString, contentHash: "h")
        var threadedName: String?
        var threadedLocation: String? = "unset"
        let out = try await SourceFetcher.fetch(ot, sourceName: "SoHo Playhouse", sourceLocation: "New York, NY",
                                                ovationtixFeed: { _, name, loc in
                                                    threadedName = name; threadedLocation = loc; return stub
                                                })
        #expect(out.normalizedHTML == "OT-STUB")
        #expect(threadedName == "SoHo Playhouse")
        #expect(threadedLocation == "New York, NY")
    }
}
