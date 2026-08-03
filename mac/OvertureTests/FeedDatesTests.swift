import Testing
import Foundation

// #1983: the feed readers built their day strings in whatever zone the Mac was set to, while the rest of
// Overture reckons in Eastern. On Dan's Mac those agree, which is exactly why this suite hands the zone in
// rather than asserting an absolute day and hoping: a test that reads the host clock passes here whether
// the reader is right or wrong, and `TZ=UTC` does not reach the test host (the bundle runs inside a
// launched app, where `TimeZone.current` reads the system preference, not the environment).
//
// The instant below is the one the VenueTix fixture actually carries, and it is a LATE show, which is the
// whole exposure: 2026-06-19 01:30 UTC is still the evening of the 18th in New York.
@Suite("Feed dates are read in Eastern, never the host zone")
struct FeedDatesTests {
    static let utc = TimeZone(identifier: "UTC")!
    // 2026-06-19T01:30:00Z, i.e. 2026-06-18 21:30 in New York.
    static let lateShow = Date(timeIntervalSince1970: 1_781_832_600)

    @Test func aDayIsReadInTheZoneItIsHanded() {
        #expect(FeedDates.day(from: Self.lateShow, zone: Self.utc) == "2026-06-19")
        #expect(FeedDates.day(from: Self.lateShow, zone: FeedDates.defaultZone) == "2026-06-18")
    }

    @Test func aDayDefaultsToEastern() {
        #expect(FeedDates.day(from: Self.lateShow) == "2026-06-18")
    }

    @Test func aTimeIsReadInTheZoneItIsHanded() {
        #expect(FeedDates.time(from: Self.lateShow, zone: Self.utc) == "01:30")
        #expect(FeedDates.time(from: Self.lateShow, zone: FeedDates.defaultZone) == "21:30")
    }

    @Test func aTimeDefaultsToEastern() {
        #expect(FeedDates.time(from: Self.lateShow) == "21:30")
    }

    // A day and its time come from ONE zone, so a card can never say the 19th at 9:30 PM for a show that
    // is the 18th at 9:30 PM. This is the invariant five copied formatter pairs each promised in a comment.
    @Test func aDayAndItsTimeAgreeAboutWhichNightItIs() {
        for zone in [Self.utc, FeedDates.defaultZone, TimeZone(identifier: "America/Los_Angeles")!] {
            let day = FeedDates.day(from: Self.lateShow, zone: zone)
            let time = FeedDates.time(from: Self.lateShow, zone: zone)
            let rebuilt = FeedDates.date(day: day, zone: zone)
            #expect(rebuilt != nil)
            // The day's own midnight plus the stated clock is the instant we started from.
            let parts = time.split(separator: ":").compactMap { Int($0) }
            #expect(parts.count == 2)
            let reassembled = rebuilt!.addingTimeInterval(TimeInterval(parts[0] * 3600 + parts[1] * 60))
            #expect(reassembled == Self.lateShow)
        }
    }

    // A day string back to that day's midnight in the zone that wrote it. 2026-06-18 begins at 04:00Z in
    // New York (EDT) and at 00:00Z in UTC.
    @Test func aDayStringParsesBackToThatZonesMidnight() {
        #expect(FeedDates.date(day: "2026-06-18", zone: Self.utc)
                == Date(timeIntervalSince1970: 1_781_740_800))
        #expect(FeedDates.date(day: "2026-06-18") == Date(timeIntervalSince1970: 1_781_755_200))
    }

    @Test func anUnparseableDayIsNilRatherThanAGuess() {
        #expect(FeedDates.date(day: "not a day") == nil)
        #expect(FeedDates.date("2026-13-45T99:99:99", format: "yyyy-MM-dd'T'HH:mm:ss") == nil)
    }

    // OPERA's feed states its dates zoneless ("2026-07-18T00:00:00") and means a local calendar day.
    // Read in UTC that midnight is four hours off the New York one, which is the drift this pins.
    @Test func aZonelessTimestampIsReadInTheZoneItIsHanded() {
        let raw = "2026-07-18T00:00:00"
        let format = "yyyy-MM-dd'T'HH:mm:ss"
        let eastern = FeedDates.date(raw, format: format)
        let utc = FeedDates.date(raw, format: format, zone: Self.utc)
        #expect(eastern != nil && utc != nil)
        #expect(eastern!.timeIntervalSince(utc!) == 4 * 3_600)
        #expect(FeedDates.day(from: eastern!) == "2026-07-18")
    }

    // The "is this show still upcoming" boundary. At 10pm in New York on 2 August the host clock in UTC is
    // already the 3rd, so a UTC start-of-day would put tonight's show behind us and drop it from the feed.
    @Test func startOfDayIsTheGivenZonesMidnight() {
        // 2026-08-03T02:00:00Z, i.e. 2026-08-02 22:00 in New York.
        let lateEvening = Date(timeIntervalSince1970: 1_785_722_400)
        #expect(FeedDates.day(from: lateEvening) == "2026-08-02")
        #expect(FeedDates.day(from: lateEvening, zone: Self.utc) == "2026-08-03")
        #expect(FeedDates.startOfDay(lateEvening) == FeedDates.date(day: "2026-08-02"))
        #expect(FeedDates.startOfDay(lateEvening, zone: Self.utc)
                == FeedDates.date(day: "2026-08-03", zone: Self.utc))
    }
}
