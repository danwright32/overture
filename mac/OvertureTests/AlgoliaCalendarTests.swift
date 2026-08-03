import Testing
import Foundation

@Suite("Algolia calendar parsing")
struct AlgoliaCalendarParseTests {
    private let sample = """
    {"results":[{"nbPages":1,"hits":[
      {"title":"The Presence of Absence","licenseename":"Cuban Cultural Center","facility":"Thalia Spanish Theatre","url":"/calendar/2026/06/25/the-presence-0700pm","startdate":1782428400000},
      {"title":"Bare Title","url":"/calendar/2026/07/10/bare","startdate":1784000000000}
    ]}]}
    """

    @Test func mapsHitFieldsToExtractedEvent() {
        let events = AlgoliaCalendar.parse(Data(sample.utf8)).events
        #expect(events.count == 2)
        let e = events[0]
        #expect(e.title == "The Presence of Absence")
        #expect(e.presenter == "Cuban Cultural Center")
        #expect(e.venue == "Thalia Spanish Theatre")
        #expect(e.performanceDate == "2026-06-25")
        #expect(e.sourceUrl == "https://www.carnegiehall.org/calendar/2026/06/25/the-presence-0700pm")
    }

    @Test func toleratesMissingPresenterAndVenue() {
        let e = AlgoliaCalendar.parse(Data(sample.utf8)).events[1]
        #expect(e.presenter == nil)
        #expect(e.venue == nil)
        #expect(e.performanceDate == "2026-07-10")
    }

    @Test func reportsPageCountForPagination() {
        #expect(AlgoliaCalendar.parse(Data(sample.utf8)).nbPages == 1)
    }

    @Test func emptyOrMalformedYieldsNoEvents() {
        #expect(AlgoliaCalendar.parse(Data("not json".utf8)).events.isEmpty)
    }

    @Test func dropsCancelledPerformances() {
        let raw = "{\"results\":[{\"nbPages\":1,\"hits\":[" +
            "{\"title\":\"Cancelled: Citywide Show\",\"url\":\"/calendar/2026/07/10/x\"}," +
            "{\"title\":\"Real Show\",\"url\":\"/calendar/2026/07/11/y\"}]}]}"
        let events = AlgoliaCalendar.parse(Data(raw.utf8)).events
        #expect(events.map(\.title) == ["Real Show"])
    }

    @Test func cleansHTMLAndZeroWidthFromTextFields() {
        let raw = "{\"results\":[{\"nbPages\":1,\"hits\":[{" +
            "\"title\":\"Anna Pierre, Piano<br />\u{200B}Virgile Roche, Piano\"," +
            "\"licenseename\":\"French-American Piano Society<br/>\"," +
            "\"facility\":\"Weill Recital Hall\",\"url\":\"/calendar/2026/07/07/z\"}]}]}"
        let e = AlgoliaCalendar.parse(Data(raw.utf8)).events[0]
        #expect(e.title == "Anna Pierre, Piano Virgile Roche, Piano")
        #expect(e.presenter == "French-American Piano Society")
    }
}

@Suite("Algolia date window")
struct AlgoliaWindowTests {
    // 2026-06-25T03:00:00Z is 2026-06-24 in New York, so the window opens on the 24th ET.
    private let now = Date(timeIntervalSince1970: 1782356400)

    @Test func spansRequestedNumberOfDays() {
        let (start, end) = AlgoliaCalendar.windowBoundsMs(today: now, windowDays: 90)
        #expect(end > start)
        let days = Double(end - start) / 86_400_000.0
        #expect(days >= 90 && days <= 92)
    }

    @Test func opensAtEasternMidnight() {
        let (start, _) = AlgoliaCalendar.windowBoundsMs(today: now, windowDays: 90)
        // 2026-06-24 00:00 America/New_York == 2026-06-24T04:00:00Z == 1782273600000 ms.
        #expect(start == 1782273600000)
    }

    @Test func paramsFilterStartDateAndPage() {
        let p = AlgoliaCalendar.params(startMs: 1000, endMs: 2000, hitsPerPage: 1000, page: 0)
        #expect(p.contains("hitsPerPage=1000"))
        #expect(p.contains("startdate"))
        #expect(p.contains("page=0"))
    }
}
