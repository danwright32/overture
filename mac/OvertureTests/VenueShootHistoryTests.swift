import Testing
import Foundation

// #1896 (part of #1887). How many times Dan has shot a room, and which of the three bands that
// falls in. Every case below is a shape measured on the real Shoots calendar and the live store
// on 2026-07-31, never an invented one (L48).

@Suite("Canonical venue key")
struct VenuePlacesCanonicalKeyTests {

    // THE REGRESSION THIS SUITE EXISTS FOR. `VenuePlaces.entry(for:)` returns a LOCATION, and 41
    // rows of the table share the identical `manhattan` value. Keying venue identity on the entry
    // would merge The Green Room 42, Merkin Hall, Asylum NYC, SoHo Playhouse, Abrons and Carnegie
    // into one venue, and the first pitch to any Manhattan room would claim Dan shoots there
    // regularly. That is the worst thing this feature could say, and the first draft of the plan
    // specified exactly it.
    @Test func venuesSharingOneLocationAreStillDifferentVenues() {
        let manhattanRooms = ["The Green Room 42", "Merkin Hall", "Asylum NYC",
                              "The Players Theatre", "SoHo Playhouse", "Abrons Arts Center",
                              "The Cutting Room", "Chain Theatre"]
        let keys = manhattanRooms.map { VenuePlaces.canonicalKey(for: $0) }
        #expect(keys.allSatisfy { $0 != nil })
        #expect(Set(keys.compactMap { $0 }).count == manhattanRooms.count)
    }

    // The calendar writes an address after a NEWLINE rather than a comma (42 of 322 events).
    // VenueNormalization.keyName splits on the first COMMA only, so without folding this, the two
    // spellings of The Green Room 42 are two venues and the count reads 1 instead of 2, on the
    // exact room that motivated #1887.
    @Test func anAddressAfterANewlineIsNotPartOfTheVenueName() {
        let withNewline = "The Green Room 42\n570 10th Ave\nNew York NY 10036\nUnited States"
        #expect(VenuePlaces.canonicalKey(for: withNewline)
                == VenuePlaces.canonicalKey(for: "The Green Room 42"))
    }

    // 40 of 322 events wrap the whole location in a matched pair of double quotes.
    @Test func aWrappingQuotePairIsNotPartOfTheVenueName() {
        #expect(VenuePlaces.canonicalKey(for: "\"Carnegie Hall, Carnegie Hall\"")
                == VenuePlaces.canonicalKey(for: "Carnegie Hall"))
    }

    // Carnegie's own rooms are Carnegie. The table already knows this; the key has to use it.
    @Test func carnegieRoomsFoldOntoCarnegie() {
        for room in ["Weill Recital Hall", "Zankel Hall", "Stern Auditorium / Perelman Stage",
                     "Resnick Education Wing", "Stern Auditorium/Perelman Stage, Carnegie Hall"] {
            #expect(VenuePlaces.canonicalKey(for: room) == VenuePlaces.canonicalKey(for: "Carnegie Hall"),
                    "\(room) should be Carnegie")
        }
    }

    // THE TRAP the red-team caught: `entry(for: "Weill Recital Hall")?.parent` is "Carnegie Hall"
    // but `entry(for: "Carnegie Hall")?.parent` is NIL, because "carnegie hall" maps to the plain
    // Manhattan entry. Any Carnegie test written against `parent` silently misses the commonest
    // spelling of all, so the key itself has to be the thing that answers.
    @Test func carnegieItselfResolvesToTheSameKeyAsItsRooms() {
        #expect(VenuePlaces.canonicalKey(for: "Carnegie Hall") == "carnegie hall")
        #expect(VenuePlaces.entry(for: "Carnegie Hall")?.parent == nil)  // pins WHY the above is needed
    }

    // "Merkin Hall at Kaufman Music Center" and "Merkin Hall" are one room. `candidates` already
    // splits an " at ", room before building; the key just has to go through it.
    @Test func aRoomNamedInsideItsBuildingIsTheRoom() {
        #expect(VenuePlaces.canonicalKey(for: "Merkin Hall at Kaufman Music Center")
                == VenuePlaces.canonicalKey(for: "Merkin Hall"))
    }

    // A venue the table has never heard of still gets a stable key, through the same fold every
    // stored natural key uses, so history at an unknown room is not silently lost.
    @Test func anUnknownVenueFallsBackToTheSharedFold() {
        #expect(VenuePlaces.canonicalKey(for: "Herald Music School, 156-03 Horace Harding Expy")
                == VenuePlaces.canonicalKey(for: "Herald Music School"))
        #expect(VenuePlaces.canonicalKey(for: "Herald Music School") == "herald music school")
    }

    @Test func nothingIsNotAVenue() {
        #expect(VenuePlaces.canonicalKey(for: nil) == nil)
        #expect(VenuePlaces.canonicalKey(for: "   ") == nil)
        #expect(VenuePlaces.canonicalKey(for: "\"\"") == nil)
    }
}

@Suite("Venue shoot history")
struct VenueShootHistoryTests {
    private let today = "2026-07-31"

    private func shoot(_ venue: String, _ date: String, _ title: String = "A show") -> ShootRecord {
        ShootRecord(venue: venue, date: date, title: title)
    }

    private func booking(_ venue: String, _ start: String, _ end: String? = nil,
                         _ name: String = "A booking") -> OvertureBooking {
        OvertureBooking(id: UUID().uuidString, clientId: "c", clientDisplayName: "Client",
                        shootName: name, startDate: start, endDate: end ?? start,
                        venueId: nil, venueName: venue)
    }

    private func band(_ venue: String, shoots: [ShootRecord] = [],
                      bookings: [OvertureBooking] = []) -> VenueShootHistory.Band? {
        VenueShootHistory(shoots: shoots, bookings: bookings, today: today).band(for: venue)
    }

    // THE MOTIVATING CASE. Dan has shot The Green Room 42 twice, and the calendar spells the room
    // two different ways. The whole feature was filed because a draft for a Green Room 42 show
    // reached for a Carnegie credential while this fact went unsaid.
    @Test func theGreenRoom42CountsBothSpellingsAsOneRoom() {
        let shoots = [
            shoot("The Green Room 42\n570 10th Ave\nNew York NY 10036\nUnited States",
                  "2018-06-22", "‘Round Midnight"),
            shoot("The Green Room 42, 570 10th Ave., New York City, New York 10036",
                  "2026-01-24", "[Troubadour Music Studio] Voice Recital"),
        ]
        #expect(band("The Green Room 42", shoots: shoots) == .aFew)
    }

    @Test func theBandBoundaries() {
        let v = "Jalopy Theatre"
        #expect(band(v) == nil)
        #expect(band(v, shoots: [shoot(v, "2024-01-01")]) == .shotBefore)
        #expect(band(v, shoots: [shoot(v, "2024-01-01"), shoot(v, "2024-02-01")]) == .aFew)
        #expect(band(v, shoots: (1...4).map { shoot(v, "2024-0\($0)-01") }) == .aFew)
        #expect(band(v, shoots: (1...5).map { shoot(v, "2024-0\($0)-01") }) == .regularly)
    }

    // Dan's call, 2026-07-31: at Carnegie the tenure credential ("nearly ten years at Carnegie
    // Hall") already says this, so a venue-history line would be the same fact twice. Decided in
    // the app rather than asked of the drafter, so it cannot drift.
    @Test func carnegieNeverCarriesAVenueHistoryLine() {
        let shoots = (1...9).map { shoot("Carnegie Hall", "2024-0\($0)-01") }
        #expect(band("Carnegie Hall", shoots: shoots) == nil)
        #expect(band("Weill Recital Hall", shoots: shoots) == nil)
        #expect(band("Stern Auditorium / Perelman Stage", shoots: shoots) == nil)
    }

    // A dress rehearsal the night before its own performance is ONE engagement, not two. Measured:
    // this is the only venue in the whole live store the rule changes (Abrons, 2 to 1).
    @Test func aRehearsalIsAbsorbedIntoTheNextNightsPerformance() {
        let shoots = [
            shoot("Abrons Arts Center", "2024-11-13", "[On Site Opera] Lucidity - Dress Rehearsal"),
            shoot("Abrons Arts Center", "2024-11-14", "[On Site Opera] Lucidity - Performance"),
        ]
        #expect(band("Abrons Arts Center", shoots: shoots) == .shotBefore)
    }

    // But a rehearsal that stands alone still counts. The Players Theatre's ONLY event in eight
    // years is "[I Mostly Blame Myself] Dress Rehearsal", and 31 live rows are at that room: Dan
    // spent that evening in there with a camera, and saying nothing would be the wrong answer.
    @Test func aStandaloneRehearsalStillCounts() {
        let shoots = [shoot("The Players Theatre", "2024-11-13",
                            "[I Mostly Blame Myself] Dress Rehearsal")]
        #expect(band("The Players Theatre", shoots: shoots) == .shotBefore)
    }

    // The rule that was REJECTED, pinned so it cannot come back. Collapsing a run of consecutive
    // dates looked right until the data killed it: these are two different DCINY concerts on
    // consecutive nights, which is two shoots, not one.
    @Test func twoDifferentConcertsOnConsecutiveNightsAreTwoShoots() {
        let shoots = [
            shoot("Roulette Intermedium", "2024-12-01", "[DCINY] Mozart’s Messiah"),
            shoot("Roulette Intermedium", "2024-12-02", "[DCINY] A Winter’s Light"),
        ]
        #expect(band("Roulette Intermedium", shoots: shoots) == .aFew)
    }

    // A shoot that has not happened yet is not a room Dan "has shot". Measured: National Sawdust
    // is exactly this today (2026-11-18), and it starts counting once the date passes.
    @Test func aFutureShootDoesNotCountYet() {
        #expect(band("National Sawdust", shoots: [shoot("National Sawdust", "2026-11-18")]) == nil)
        #expect(band("National Sawdust", shoots: [shoot("National Sawdust", "2026-07-30")]) == .shotBefore)
    }

    // Today is not "before today". A show tonight has not been shot yet.
    @Test func todayItselfDoesNotCountYet() {
        #expect(band("Jalopy Theatre", shoots: [shoot("Jalopy Theatre", "2026-07-31")]) == nil)
    }

    // Downbeat writes its bookings onto the same calendar (via Fantastical), so the same shoot
    // arrives from both sources. Measured on the live export: both live bookings are already on
    // the calendar, and once dates are Eastern the two agree exactly.
    @Test func aBookingAlsoOnTheCalendarIsNotCountedTwice() {
        let shoots = [shoot("Greenwich House Theater (27 Barrow St, New York, NY 10014)",
                            "2026-07-30", "[Pete White] BLUDLINE")]
        let bookings = [booking("Greenwich House Theater", "2026-07-30")]
        #expect(band("Greenwich House Theater", shoots: shoots, bookings: bookings) == .shotBefore)
    }

    // The forward half of the hybrid: a booking the calendar export predates still counts.
    @Test func aBookingNotOnTheCalendarStillCounts() {
        #expect(band("Greenwich House Theater",
                     bookings: [booking("Greenwich House Theater", "2026-07-30")]) == .shotBefore)
    }

    // A Downbeat booking carries a date RANGE, not one date.
    @Test func aMultiDayBookingCountsEachOfItsDays() {
        #expect(band("Roulette Intermedium",
                     bookings: [booking("Roulette Intermedium", "2026-07-27", "2026-07-29")]) == .aFew)
    }

    // A backwards or absurd range must not hang or explode into thousands of dates.
    @Test func abackwardsBookingRangeIsSurvivable() {
        #expect(band("Roulette Intermedium",
                     bookings: [booking("Roulette Intermedium", "2026-07-29", "2026-07-27")]) == .shotBefore)
    }

    // A booking with no usable venue cannot invent one.
    @Test func abookingWithABlankVenueIsIgnored() {
        #expect(band("Jalopy Theatre", bookings: [booking("", "2026-07-30")]) == nil)
    }

    // The count must not leak across rooms that merely share a city (the 41-Manhattan-rows trap,
    // measured end to end rather than only at the key).
    @Test func historyAtOneManhattanRoomSaysNothingAboutAnother() {
        let shoots = (1...9).map { shoot("The Cutting Room", "2024-0\($0)-01") }
        #expect(band("The Cutting Room", shoots: shoots) == .regularly)
        #expect(band("Asylum NYC", shoots: shoots) == nil)
    }
}
