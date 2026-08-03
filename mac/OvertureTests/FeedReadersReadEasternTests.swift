import Testing
import Foundation
@testable import Overture

// #1983: five readers turn a feed's dates into Overture's own. Each used to build its day string in
// whatever zone the Mac was set to, so a 9:30pm show reads as the NEXT day the moment the host clock is
// not Eastern, which moves the row to the wrong date group, the wrong lead-time window and the wrong side
// of the self-booking clash check.
//
// Every test here hands the zone in rather than asserting an absolute day and hoping, because on Dan's Mac
// the host zone IS Eastern: an absolute assertion passes whether the reader is right or wrong, and `TZ=UTC`
// does not reach the test host. Handing UTC in is what makes a wrong reader go red on this machine.
//
// The fixtures are the suites' own real captures, not invented shapes, so the instants are ones these
// feeds genuinely publish.
@Suite("Feed readers read their dates in Eastern, never the host zone")
struct FeedReadersReadEasternTests {
    static let utc = TimeZone(identifier: "UTC")!

    // MARK: - VenueTix: a true curtain instant, so the day itself moves

    // The fixture's first row is `dateTime` 1781832600000, i.e. 2026-06-19 01:30 UTC and 2026-06-18 21:30
    // in New York. A late show is precisely the case that lands on the wrong day.
    @Test func venueTixReadsALateShowAsTheEasternNightItPlays() throws {
        let events = try VenueTixCalendar.parseEvents(Data(VenueTixCalendarTests.feed.utf8))
        let eastern = VenueTixCalendar.extractedEvents(from: events, presenter: "Green Room 42",
                                                      venue: nil, location: nil)
        #expect(eastern[0].performanceDate == "2026-06-18")
        #expect(eastern[0].startTimes == ["21:30"])

        let read = VenueTixCalendar.extractedEvents(from: events, presenter: "Green Room 42",
                                                    venue: nil, location: nil, zone: Self.utc)
        #expect(read[0].performanceDate == "2026-06-19")
        #expect(read[0].startTimes == ["01:30"])
    }

    // The synthesized document the extractor reads carries the same day, from the same zone, so the two
    // paths into the queue can never disagree about which night a show is.
    @Test func venueTixWritesTheSameDayIntoItsSynthesizedDocument() throws {
        let events = try VenueTixCalendar.parseEvents(Data(VenueTixCalendarTests.feed.utf8))
        #expect(VenueTixCalendar.listingHTML(events, venueName: "Green Room 42").contains("2026-06-18"))
        #expect(VenueTixCalendar.listingHTML(events, venueName: "Green Room 42", zone: Self.utc)
                    .contains("2026-06-19"))
    }

    // MARK: - Squarespace: already Eastern, and now provably so rather than incidentally

    // The fixture's second event is 2026-12-11 00:00 UTC, i.e. 2026-12-10 19:00 in New York: a 7pm concert
    // that a UTC host would file on the following day.
    @Test func squarespaceReadsAnEveningConcertAsTheEasternNightItPlays() throws {
        let events = try SquarespaceCalendar.parseEvents(Data(SquarespaceCalendarTests.eventsFeed.utf8))
        let evening = events[1]
        let eastern = SquarespaceCalendar.extractedEvents(from: [evening], orgName: "Org", location: nil)
        #expect(eastern[0].performanceDate == "2026-12-10")
        #expect(eastern[0].startTimes == ["19:00"])

        let read = SquarespaceCalendar.extractedEvents(from: [evening], orgName: "Org", location: nil,
                                                       zone: Self.utc)
        #expect(read[0].performanceDate == "2026-12-11")
        #expect(read[0].startTimes == ["00:00"])
    }

    // MARK: - OvationTix: a day-granular feed, so the exposure is the "still upcoming" boundary

    // 2026-07-24 02:00 UTC is 2026-07-23 22:00 in New York: the evening of the 23rd, with that night's
    // shows still on. Read against the host clock in UTC it is already the 24th, and every show on the
    // 23rd silently leaves the feed, which the reconcile then reads as those shows being cancelled.
    @Test func ovationTixKeepsTonightsShowsLateInTheEasternEvening() throws {
        let lateEvening = Date(timeIntervalSince1970: 1_784_858_400)
        let data = Data(OvationTixCalendarTests.feed.utf8)

        let eastern = OvationTixCalendar.upcoming(try OvationTixCalendar.parseEvents(data), now: lateEvening)
        #expect(eastern.contains { OvationTixCalendar.extractedEvents(from: [$0], presenter: "SoHo Playhouse",
                                                                     venue: nil, location: nil)[0]
                                       .performanceDate == "2026-07-23" })

        let read = OvationTixCalendar.upcoming(try OvationTixCalendar.parseEvents(data, zone: Self.utc),
                                               now: lateEvening, zone: Self.utc)
        #expect(!read.contains { OvationTixCalendar.extractedEvents(from: [$0], presenter: "SoHo Playhouse",
                                                                   venue: nil, location: nil, zone: Self.utc)[0]
                                     .performanceDate == "2026-07-23" })
    }

    // The day a feed states survives the round trip through the reader unchanged, in whatever zone it is
    // read, because a day-granular feed's day is its own assertion and nothing here may shift it.
    @Test func ovationTixEchoesTheDayTheFeedStated() throws {
        let data = Data(OvationTixCalendarTests.feed.utf8)
        for zone in [FeedDates.defaultZone, Self.utc] {
            let events = try OvationTixCalendar.parseEvents(data, zone: zone)
            let days = Set(OvationTixCalendar.extractedEvents(from: events, presenter: "SoHo Playhouse",
                                                             venue: nil, location: nil, zone: zone)
                               .map(\.performanceDate))
            #expect(days == ["2026-07-23", "2026-07-24", "2026-07-25"])
        }
    }

    // MARK: - TicketTailor: the same day-granular boundary

    // 2026-07-22 02:00 UTC is 2026-07-21 22:00 in New York, so the 21st's show is still tonight's.
    @Test func ticketTailorKeepsTonightsShowLateInTheEasternEvening() throws {
        let lateEvening = Date(timeIntervalSince1970: 1_784_685_600)
        let html = TicketTailorCalendarTests.populated

        let eastern = TicketTailorCalendar.upcoming(try TicketTailorCalendar.parseWidget(html),
                                                    now: lateEvening)
        #expect(TicketTailorCalendar.extractedEvents(from: eastern, venueName: "The Cell", location: nil)
                    .contains { $0.performanceDate == "2026-07-21" })

        let read = TicketTailorCalendar.upcoming(try TicketTailorCalendar.parseWidget(html, zone: Self.utc),
                                                 now: lateEvening, zone: Self.utc)
        #expect(!TicketTailorCalendar.extractedEvents(from: read, venueName: "The Cell", location: nil,
                                                      zone: Self.utc)
                    .contains { $0.performanceDate == "2026-07-21" })
    }

    // MARK: - OPERA America: zoneless timestamps, which mean a local calendar day

    // The feed states "2026-07-18T00:00:00" with no zone at all, so which INSTANT that is depends entirely
    // on the zone it is read in. Read Eastern it is 04:00 UTC, the New York midnight Overture reckons by.
    @Test func operaAmericaReadsAZonelessDateAsEasternMidnight() throws {
        let data = Data(OperaAmericaCalendarTests.feedPage1.utf8)
        #expect(try OperaAmericaCalendar.parsePage(data).events[0].date
                == Date(timeIntervalSince1970: 1_784_347_200))
        #expect(try OperaAmericaCalendar.parsePage(data, zone: Self.utc).events[0].date
                == Date(timeIntervalSince1970: 1_784_332_800))
    }

    // The horizon window the feed is asked for is Dan's four months in New York, not the host's.
    @Test func operaAmericaAsksForItsWindowInEastern() {
        // 2026-08-03 02:00 UTC, i.e. late on 2 August in New York.
        let lateEvening = Date(timeIntervalSince1970: 1_785_722_400)
        let request = OperaAmericaCalendar.filteredRequest(host: "operaamerica.org", from: lateEvening,
                                                          to: lateEvening, page: 1, pageSize: 12)
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("2026-08-02"))
        #expect(!body.contains("2026-08-03"))
    }

    // Four months on from that same late evening is 2 December in New York and the 3rd in UTC, so the far
    // edge of the horizon is a day out too if the host clock decides it.
    @Test func operaAmericasHorizonEndsOnAnEasternDay() {
        let lateEvening = Date(timeIntervalSince1970: 1_785_722_400)
        #expect(FeedDates.day(from: OperaAmericaCalendar.windowEnd(from: lateEvening)) == "2026-12-02")
        #expect(FeedDates.day(from: OperaAmericaCalendar.windowEnd(from: lateEvening, zone: Self.utc),
                              zone: Self.utc) == "2026-12-03")
    }
}
