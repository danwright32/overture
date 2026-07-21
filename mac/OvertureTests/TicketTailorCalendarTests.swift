import Testing
import Foundation
@testable import Overture

// #1280 Phase 1 (#1293): the parser over the TicketTailor all-tickets-calendar widget's embedded event
// JSON. The widget server-renders a `var selectableDates = ...;` assignment. Fixtures below use the REAL
// field names captured from tickettailorexamples (populated) and thecelltheatre (empty) on 2026-07-21.
@Suite("TicketTailor calendar parser (#1280)")
struct TicketTailorCalendarTests {
    // A faithful slice of the real populated widget: series 429862 "Beach visits" plays on BOTH dates
    // (a recurring show repeats under every date key it plays), and a second single-date series 500001
    // "Sunset Jazz" whose venue field is blank (so it must fall back to the configured venue name).
    static let populated = #"""
    <html><body><script>
    var selectableDates = {"2026-07-21":{"available":true,"sold_out":false,"formatted_date":"Tue 21 Jul 2026","event_series":[{"series_id":429862,"name":"Beach visits","venue":"Sparkling Waters, Golden sands","event_page_url":"/events/tickettailorexamples/429862"}]},"2026-07-22":{"available":true,"formatted_date":"Wed 22 Jul 2026","event_series":[{"series_id":429862,"name":"Beach visits","venue":"Sparkling Waters, Golden sands","event_page_url":"/events/tickettailorexamples/429862"},{"series_id":500001,"name":"Sunset Jazz","venue":"","event_page_url":"/events/tickettailorexamples/500001"}]}};
    </script></body></html>
    """#

    // The Cell's REAL empty widget: the assignment is an empty ARRAY, not an object.
    static let empty = #"<html><body><script>var selectableDates = [];</script></body></html>"#

    @Test func parsesEveryDateSeriesRowFromThePopulatedWidget() throws {
        let events = try TicketTailorCalendar.parseWidget(Self.populated)
        // 3 rows: Beach visits on 07-21 and 07-22, plus Sunset Jazz on 07-22.
        #expect(events.count == 3)
        #expect(events.map(\.name).sorted() == ["Beach visits", "Beach visits", "Sunset Jazz"])
        let beach = events.filter { $0.name == "Beach visits" }
        #expect(beach.count == 2)
        #expect(beach.allSatisfy { $0.seriesId == "429862" })
        #expect(beach.allSatisfy { $0.venue == "Sparkling Waters, Golden sands" })
    }

    // THE critical case (#1280 blocking fix): the empty widget's assignment is `[]`, which decodes as an
    // array, not the event-object map. It must read as a quiet empty calendar, NEVER a feedShapeChanged
    // failure (which reconcile would treat as every show cancelled).
    @Test func anEmptyArrayWidgetIsAQuietEmptyCalendarNotDrift() throws {
        #expect(try TicketTailorCalendar.parseWidget(Self.empty).isEmpty)
    }

    @Test func aWidgetWithNoAssignmentAtAllIsEmptyNotAnError() throws {
        #expect(try TicketTailorCalendar.parseWidget("<html><body>nothing here</body></html>").isEmpty)
    }

    // A non-empty object whose series objects are present but missing name/series_id is a SHAPE CHANGE,
    // not an empty calendar: fail loud so a silently-empty list can't read as an off-season.
    @Test func aDriftedSeriesShapeFailsLoud() {
        let drifted = #"<script>var selectableDates = {"2026-07-21":{"event_series":[{"foo":1,"bar":2}]}};</script>"#
        #expect(throws: SourceFetchError.feedShapeChanged) {
            _ = try TicketTailorCalendar.parseWidget(drifted)
        }
    }

    // ...but a date entry whose event_series is genuinely EMPTY (a date with no shows) is real emptiness,
    // not drift. Nesting-aware: "series present but unparseable" is drift; "no series at all" is empty.
    @Test func aDateWithAnEmptySeriesListIsEmptyNotDrift() throws {
        let noSeries = #"<script>var selectableDates = {"2026-07-21":{"event_series":[]}};</script>"#
        #expect(try TicketTailorCalendar.parseWidget(noSeries).isEmpty)
    }

    // A venue string containing the JSON delimiter characters must not break the balanced extraction of
    // the assignment (the naive "read until the first ;" would truncate mid-object).
    @Test func aVenueContainingPunctuationDoesNotTruncateTheParse() throws {
        let tricky = #"""
        <script>var selectableDates = {"2026-08-01":{"event_series":[{"series_id":7,"name":"A; B {night}","venue":"Room 1; Room 2","event_page_url":"/events/x/7"}]}};</script>
        """#
        let events = try TicketTailorCalendar.parseWidget(tricky)
        #expect(events.count == 1)
        #expect(events.first?.name == "A; B {night}")
        #expect(events.first?.venue == "Room 1; Room 2")
    }

    // MARK: - mapping to ExtractedEvent (Dan's decisions: feed venue then configured fallback; one card).

    @Test func mapsToExtractedEventsWithFeedVenueThenConfiguredFallback() throws {
        let events = try TicketTailorCalendar.parseWidget(Self.populated)
        let mapped = TicketTailorCalendar.extractedEvents(from: events, venueName: "The Cell",
                                                          location: "New York, NY")
        #expect(mapped.count == 3)

        let beach = try #require(mapped.first { $0.title == "Beach visits" })
        #expect(beach.venue == "Sparkling Waters, Golden sands")   // the feed's own venue field
        #expect(beach.location == "New York, NY")
        #expect(beach.presenter == "The Cell")
        #expect(beach.sourceUrl == "https://www.tickettailor.com/events/tickettailorexamples/429862")

        let jazz = try #require(mapped.first { $0.title == "Sunset Jazz" })
        #expect(jazz.venue == "The Cell")                          // blank feed venue -> configured fallback
    }

    // Dan's decision: a recurring show (one series_id across many dates) collapses to ONE card. The shared
    // series_id must survive onto the ExtractedEvents so RunGrouping folds them; a single-date show gets no
    // seriesId so it is never falsely run-collapsed.
    @Test func aMultiDateSeriesCarriesItsSharedIdButASingleDateOneDoesNot() throws {
        let events = try TicketTailorCalendar.parseWidget(Self.populated)
        let mapped = TicketTailorCalendar.extractedEvents(from: events, venueName: "The Cell", location: nil)
        let beach = mapped.filter { $0.title == "Beach visits" }
        #expect(beach.allSatisfy { $0.seriesId == "429862" })      // two dates, shared id -> one run
        #expect(mapped.first { $0.title == "Sunset Jazz" }?.seriesId == nil)  // single date -> no run
    }

    @Test func performanceDatesComeFromTheDateKeys() throws {
        let events = try TicketTailorCalendar.parseWidget(Self.populated)
        let mapped = TicketTailorCalendar.extractedEvents(from: events, venueName: "The Cell", location: nil)
        #expect(Set(mapped.map(\.performanceDate)) == ["2026-07-21", "2026-07-22"])
    }
}
