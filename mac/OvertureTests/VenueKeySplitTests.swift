import Testing
import Foundation

// #1899: the shoot count unions the Shoots calendar and Downbeat's bookings on (venue key, date). If the
// two name one room in ways that fold to DIFFERENT keys, the room's history splits in two, each half
// reachable only by whichever spelling a prospect carries, and the pitch understates how well Dan knows
// the room with nothing saying so.
//
// The observable signature: a Downbeat booking whose venue folds to a key no calendar shoot uses, on a
// night the calendar DOES hold a shoot under another key. Downbeat writes its bookings onto that calendar,
// so the same night appearing under two keys is the same room named two ways, not two rooms.
@Suite("The calendar and Downbeat name a room the same way (#1899)")
struct VenueKeySplitTests {
    private func shoot(_ venue: String, _ date: String) -> ShootRecord {
        ShootRecord(venue: venue, date: date, title: "An invented show")
    }

    private func booking(_ venue: String, _ start: String, _ end: String? = nil) -> OvertureBooking {
        OvertureBooking(id: UUID().uuidString, clientId: "c", clientDisplayName: "Invented Client",
                        shootName: "An invented booking", startDate: start, endDate: end ?? start,
                        venueId: nil, venueName: venue)
    }

    // Two names chosen because they fold to different keys today: a room and a building it is not
    // recorded as being inside. Asserted rather than assumed, so a later alias does not quietly turn this
    // test into one about two names that agree.
    private let calendarName = "Roulette Intermedium"
    private let downbeatName = "Roulette Brooklyn Performance Space"

    @Test func theFixtureNamesReallyFoldApart() {
        let a = VenuePlaces.canonicalKey(for: calendarName)
        let b = VenuePlaces.canonicalKey(for: downbeatName)
        #expect(a != nil && b != nil)
        #expect(a != b, "the two fixture names now fold together, so pick two that do not")
    }

    @Test func aBookingNamedApartFromTheCalendarOnTheSameNightIsASplit() {
        let splits = VenueKeySplit.find(shoots: [shoot(calendarName, "2026-03-01")],
                                        bookings: [booking(downbeatName, "2026-03-01")])
        #expect(splits == [VenueKeySplit.Split(downbeatVenue: downbeatName, calendarVenue: calendarName,
                                               date: "2026-03-01")])
    }

    // The healthy union: the same spelling on both sides folds to one key and says nothing.
    @Test func theSameNameOnBothSidesIsNotASplit() {
        #expect(VenueKeySplit.find(shoots: [shoot(calendarName, "2026-03-01")],
                                   bookings: [booking(calendarName, "2026-03-01")]).isEmpty)
    }

    // A room the calendar already knows by this key elsewhere is not split, whatever else was on that
    // night: the union already joins them.
    @Test func aKeyTheCalendarAlreadyUsesIsNeverASplit() {
        #expect(VenueKeySplit.find(shoots: [shoot(downbeatName, "2025-01-01"), shoot(calendarName, "2026-03-01")],
                                   bookings: [booking(downbeatName, "2026-03-01")]).isEmpty)
    }

    // A genuinely new room with nothing on the calendar that night is simply new, not split.
    @Test func aNewRoomOnANightTheCalendarHasNothingIsNotASplit() {
        #expect(VenueKeySplit.find(shoots: [shoot(calendarName, "2026-02-01")],
                                   bookings: [booking(downbeatName, "2026-03-01")]).isEmpty)
    }

    // A multi day booking is checked on every one of its days, as the union expands it.
    @Test func everyDayOfABookingIsCompared() {
        let splits = VenueKeySplit.find(shoots: [shoot(calendarName, "2026-03-03")],
                                        bookings: [booking(downbeatName, "2026-03-01", "2026-03-04")])
        #expect(splits.map(\.date) == ["2026-03-03"])
    }

    // One pair of names is one finding however many nights it recurs on.
    @Test func onePairOfNamesIsReportedOnce() {
        let splits = VenueKeySplit.find(
            shoots: [shoot(calendarName, "2026-03-01"), shoot(calendarName, "2026-04-01")],
            bookings: [booking(downbeatName, "2026-03-01"), booking(downbeatName, "2026-04-01")])
        #expect(splits.count == 1)
    }

    // MARK: - The line Dan reads

    @Test func theMastheadNamesBothSpellingsAndOffersTheReRead() throws {
        let split = VenueKeySplit.Split(downbeatVenue: downbeatName, calendarVenue: calendarName,
                                        date: "2026-03-01")
        let notices = AppNotices.current(venueSplits: [split], status: StatusLine())
        let line = try #require(notices.first { $0.text.contains(downbeatName) },
                                "the split must reach the masthead: \(notices.map(\.text))")
        #expect(line.text.contains(calendarName))
        #expect(line.tone == .warning)
        #expect(line.action == .recheckDownbeatExport)
        #expect(AppNotices.current(venueSplits: [], status: StatusLine()).isEmpty)
    }

    @Test func severalSplitsShareOneLineAndListEachPairInItsHelp() throws {
        let splits = [
            VenueKeySplit.Split(downbeatVenue: downbeatName, calendarVenue: calendarName, date: "2026-03-01"),
            VenueKeySplit.Split(downbeatVenue: "Invented Hall North", calendarVenue: "Invented Hall",
                                date: "2026-04-01"),
        ]
        let notices = AppNotices.current(venueSplits: splits, status: StatusLine())
        #expect(notices.count == 1)
        let help = try #require(notices.first?.help)
        #expect(help.contains(downbeatName) && help.contains("Invented Hall North"))
    }
}

// #1899's measurement against Dan's real files, read only. Opt in, and SKIPPED everywhere by default. It
// never finds a real file by itself: the paths are handed in by whoever runs it, so a test run can only
// read live data when somebody has typed the paths (L2, and `TestsCannotReachSharedStateTests`).
//
//     TEST_RUNNER_OVERTURE_VENUE_SPLIT_SHOOTS="$HOME/Library/Application Support/Overture/overture-shoot-history.json" \
//     TEST_RUNNER_OVERTURE_VENUE_SPLIT_EXPORT="$HOME/Library/Application Support/Overture/downbeat-export.json" \
//         mac/scripts/run-tests-locked.sh -only-testing:OvertureTests/VenueKeySplitLiveMeasurement
//
// Prints venue names and keys only (public businesses), never a client or a title.
@Suite("Venue key split, measured on the live files (#1899, opt-in)")
struct VenueKeySplitLiveMeasurement {
    static var shootsPath: String? { ProcessInfo.processInfo.environment["OVERTURE_VENUE_SPLIT_SHOOTS"] }
    static var exportPath: String? { ProcessInfo.processInfo.environment["OVERTURE_VENUE_SPLIT_EXPORT"] }

    @Test(.enabled(if: VenueKeySplitLiveMeasurement.shootsPath != nil
                   && VenueKeySplitLiveMeasurement.exportPath != nil))
    func measureTheLiveFiles() throws {
        let now = Date()
        let shoots = ShootHistory.loadWithHealth(from: URL(fileURLWithPath: try #require(Self.shootsPath)),
                                                 now: now)
        let export = DownbeatBridge.loadWithHealth(from: URL(fileURLWithPath: try #require(Self.exportPath)),
                                                   now: now)
        let calendarKeys = Set(shoots.shoots.compactMap { VenuePlaces.canonicalKey(for: $0.venue) })
        let bookingKeys = Set(export.bookings.compactMap { VenuePlaces.canonicalKey(for: $0.venueName) })
        let splits = VenueKeySplit.find(shoots: shoots.shoots, bookings: export.bookings)
        print("venue-key-split: shoot history \(shoots.health), \(shoots.shoots.count) shoots, "
              + "\(calendarKeys.count) calendar keys")
        print("venue-key-split: Downbeat export \(export.health), \(export.bookings.count) bookings, "
              + "\(bookingKeys.count) booking keys, \(bookingKeys.subtracting(calendarKeys).count) used by no calendar shoot")
        print("venue-key-split: \(splits.count) split(s)")
        for split in splits {
            print("venue-key-split:   \(split.date)  Downbeat \(VenueKeySplit.displayName(split.downbeatVenue))"
                  + "  Calendar \(VenueKeySplit.displayName(split.calendarVenue))")
        }
        for key in bookingKeys.subtracting(calendarKeys).sorted() {
            print("venue-key-split:   no calendar shoot uses key \(key)")
        }
        #expect(!shoots.shoots.isEmpty, "read no shoots from the file given, so nothing was measured")
    }
}
