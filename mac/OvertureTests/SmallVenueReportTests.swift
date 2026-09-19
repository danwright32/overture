import Testing
import Foundation

// #1902: a room with 1 to 4 shoots has no band saturation to protect it, so one stray calendar entry
// (a training session, a reception) moves it from "you've shot here before" to "a few shows here" in an
// email to somebody who works there. A keyword filter is the wrong tool (the only event at one room in
// eight years is a standalone dress rehearsal), so the remedy is a person LOOKING: a periodic report of the
// small rooms with what is behind each band.
//
// The report is built here, in the test target, because it is a diagnostic rather than something the app
// shows, and it reuses the app's own rules rather than restating them: the band comes from
// `VenueShootHistory` (so the report says exactly what a pitch would), and rooms are grouped by
// `VenuePlaces.canonicalKey` (so one room spelled two ways is one entry, as the count sees it).
//
// TITLES ARE PRIVATE (#1904): they can carry a client's payment notes. The report is printed on this Mac
// only, by `scripts/report-small-venues.sh`, and is never pasted into GitHub. Every title below is invented.
enum SmallVenueReport {
    struct Event: Equatable {
        var date: String
        var title: String
        var source: String          // "calendar" or "Downbeat"
    }

    struct Entry: Equatable {
        var venue: String           // the first spelling met, for a person to recognise the room
        var band: VenueShootHistory.Band
        var events: [Event]
    }

    // Every room whose band is one of the two small ones, with every past entry behind it, rehearsals
    // included, because a rehearsal the rule absorbed is still something a person may want to see.
    static func build(shoots: [ShootRecord], bookings: [OvertureBooking], today: String) -> [Entry] {
        let history = VenueShootHistory(shoots: shoots, bookings: bookings, today: today)
        // Keyed by the canonical key, holding the first RAW spelling met, so the band is asked of a string
        // the app itself would fold and the display name is derived from it once.
        var byKey: [String: (venue: String, events: [Event])] = [:]
        func add(_ venue: String, _ date: String, _ title: String, _ source: String) {
            guard date < today, let key = VenuePlaces.canonicalKey(for: venue) else { return }
            byKey[key, default: (venue, [])].events
                .append(Event(date: date, title: title, source: source))
        }
        for shoot in shoots { add(shoot.venue, shoot.date, shoot.title, "calendar") }
        for booking in bookings {
            for date in EasternDate.days(from: booking.startDate, through: booking.endDate) {
                add(booking.venueName, date, booking.shootName, "Downbeat")
            }
        }
        return byKey.values.compactMap { group -> Entry? in
            guard let band = history.band(for: group.venue), band == .shotBefore || band == .aFew else {
                return nil
            }
            return Entry(venue: VenueKeySplit.displayName(group.venue), band: band,
                         events: group.events.sorted { ($0.date, $0.title) < ($1.date, $1.title) })
        }
        .sorted { $0.venue.localizedCaseInsensitiveCompare($1.venue) == .orderedAscending }
    }

    static func bandWords(_ band: VenueShootHistory.Band) -> String {
        switch band {
        case .shotBefore: return "shot here before (1 night)"
        case .aFew: return "a few (2 to 4 nights)"
        case .regularly: return "regularly (5 or more)"
        }
    }

    static func render(_ entries: [Entry], today: String) -> String {
        var lines = ["Small venue report, \(today): \(Plural.count(entries.count, "room")) with 1 to 4 shoots.", ""]
        for entry in entries {
            lines.append("\(entry.venue)  [\(bandWords(entry.band))]")
            for event in entry.events {
                lines.append("  \(event.date)  \(event.source)  \(event.title)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

@Suite("Small venue report (#1902)")
struct SmallVenueReportTests {
    private let today = "2026-09-19"

    private func shoot(_ venue: String, _ date: String, _ title: String) -> ShootRecord {
        ShootRecord(venue: venue, date: date, title: title)
    }

    @Test func aSmallRoomIsListedWithEveryEntryBehindItsBand() {
        let entries = SmallVenueReport.build(
            shoots: [shoot("Roulette Intermedium", "2025-02-01", "[Invented Ensemble] Winter Concert"),
                     shoot("Roulette Intermedium", "2025-05-01", "Invented staff training")],
            bookings: [], today: today)
        #expect(entries.count == 1)
        #expect(entries.first?.band == .aFew)
        #expect(entries.first?.events.map(\.title)
                == ["[Invented Ensemble] Winter Concert", "Invented staff training"])
    }

    // A room past the small bands is saturated and not what this report is for.
    @Test func aRoomWithFiveOrMoreShootsIsLeftOut() {
        let shoots = (1...5).map { shoot("Roulette Intermedium", "2025-0\($0)-01", "Invented show \($0)") }
        #expect(SmallVenueReport.build(shoots: shoots, bookings: [], today: today).isEmpty)
    }

    // Downbeat's bookings count toward the band exactly as the union counts them, so they are listed too.
    @Test func aDownbeatBookingIsListedBesideTheCalendar() {
        let booking = OvertureBooking(id: "b", clientId: "c", clientDisplayName: "Invented Client",
                                      shootName: "Invented booking", startDate: "2025-03-01",
                                      endDate: "2025-03-01", venueId: nil, venueName: "Roulette Intermedium")
        let entries = SmallVenueReport.build(
            shoots: [shoot("Roulette Intermedium", "2025-02-01", "Invented show")],
            bookings: [booking], today: today)
        #expect(entries.first?.events.map(\.source) == ["calendar", "Downbeat"])
    }

    // Two spellings of one room are one entry, as the count sees them.
    @Test func twoSpellingsOfOneRoomAreOneEntry() {
        let entries = SmallVenueReport.build(
            shoots: [shoot("The Green Room 42\n570 10th Ave\nNew York NY 10036\nUnited States", "2018-06-22",
                           "Invented cabaret"),
                     shoot("The Green Room 42, 570 10th Ave., New York City, New York 10036", "2026-01-24",
                           "Invented recital")],
            bookings: [], today: today)
        #expect(entries.count == 1)
        #expect(entries.first?.venue == "The Green Room 42")
    }

    // A night not yet shot is not history, here as in the band.
    @Test func aFutureEntryIsNotListed() {
        #expect(SmallVenueReport.build(shoots: [shoot("Roulette Intermedium", "2027-01-01", "Invented future")],
                                       bookings: [], today: today).isEmpty)
    }

    @Test func theRenderedReportNamesTheRoomTheBandAndEachEntry() {
        let text = SmallVenueReport.render(
            [SmallVenueReport.Entry(venue: "Roulette Intermedium", band: .shotBefore,
                                    events: [.init(date: "2025-02-01", title: "Invented show",
                                                   source: "calendar")])],
            today: today)
        #expect(text.contains("1 room with 1 to 4 shoots"))
        #expect(text.contains("Roulette Intermedium  [shot here before (1 night)]"))
        #expect(text.contains("  2025-02-01  calendar  Invented show"))
    }
}

// The report itself, against Dan's real files. Opt in and SKIPPED everywhere by default. It never finds a
// real file by itself: `scripts/report-small-venues.sh` hands it the two paths and the output path, so a
// test run reads live data only when somebody asked for this report (L2, `TestsCannotReachSharedStateTests`).
@Suite("Small venue report, written from the live files (#1902, opt-in)")
struct SmallVenueReportLive {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var outputPath: String? { env["OVERTURE_SMALL_VENUES_OUT"] }
    static var shootsPath: String? { env["OVERTURE_SMALL_VENUES_SHOOTS"] }
    static var exportPath: String? { env["OVERTURE_SMALL_VENUES_EXPORT"] }

    @Test(.enabled(if: SmallVenueReportLive.outputPath != nil))
    func writeTheReport() throws {
        let output = try #require(Self.outputPath)
        let shootsPath = try #require(Self.shootsPath, "the script names the shoot history file")
        let exportPath = try #require(Self.exportPath, "the script names the Downbeat export")
        let now = Date()
        let shoots = ShootHistory.loadWithHealth(from: URL(fileURLWithPath: shootsPath), now: now)
        let export = DownbeatBridge.loadWithHealth(from: URL(fileURLWithPath: exportPath), now: now)
        // Refuse rather than write an empty report: an unreadable file and a calendar with no small rooms
        // must not read alike (L98). The script reports a missing report as UNMEASURED.
        #expect(!shoots.shoots.isEmpty, "the shoot history file gave no shoots (\(shoots.health))")
        guard !shoots.shoots.isEmpty else { return }
        let today = EasternDate.today(now)
        let report = SmallVenueReport.render(
            SmallVenueReport.build(shoots: shoots.shoots, bookings: export.bookings, today: today), today: today)
        try report.write(toFile: output, atomically: true, encoding: .utf8)
    }
}
