import Foundation

// #1896 (part of #1887): how many times Dan has shot a room, and which of the three bands that
// falls in. The band is the only thing that ever leaves this type: Dan's rule is "never an exact
// number", and the way to stop a prompt stating a number is to never send it one (L27).
//
// TWO SOURCES, UNIONED, NO CUTOVER DATE. The Shoots calendar backfills a decade; Downbeat carries
// what is booked from here on. Downbeat also writes its bookings ONTO that calendar (via
// Fantastical), so the same shoot really does arrive twice, and the union is keyed on
// (venue, date) so a duplicate collapses on its own. That is also what makes re-importing the
// calendar safe: there is no "everything before date X" constant to get wrong.
//
// STRICTLY IN THE PAST. A shoot next November is not a room Dan "has shot", and counting only
// past dates is what removes the need for a cutoff in the first place.
// #1964: Equatable so the held copy can tell a refresh that found something new from one that found the
// same history again, and stay silent for the second. Synthesised from its one stored property.
struct VenueShootHistory: Equatable {

    enum Band: String, Equatable, Sendable, CaseIterable {
        case shotBefore = "shot_before"   // 1
        case aFew = "a_few"               // 2 to 4
        case regularly = "regularly"      // 5+

        static func forCount(_ count: Int) -> Band? {
            switch count {
            case ..<1: return nil
            case 1: return .shotBefore
            case 2...4: return .aFew
            default: return .regularly
            }
        }
    }

    // One night Dan shot at a venue, after the two sources are merged and rehearsals absorbed.
    // Carries its title so the review card can show WHAT is behind a band rather than asking Dan
    // to trust a bare word (#1897).
    struct Shoot: Equatable, Sendable {
        var date: String
        var titles: [String]
    }

    private let byVenue: [String: [Shoot]]

    // Carnegie's key, resolved through the same function everything else uses. NOT a check against
    // `Entry.parent`: `entry(for: "Carnegie Hall")?.parent` is nil (it maps to the plain Manhattan
    // entry), so a parent-based test passes for Weill and Zankel and silently misses the
    // commonest spelling of Carnegie there is.
    // copy-inventory:ignore-start  A venue name looked UP in the table, never shown to Dan (#1887)
    private static let carnegieKey = VenuePlaces.canonicalKey(for: "Carnegie Hall")
    // copy-inventory:ignore-end

    init(shoots: [ShootRecord], bookings: [OvertureBooking], today: String) {
        var titlesByVenueDate: [String: [String: [String]]] = [:]

        func record(venue: String?, date: String, title: String) {
            guard let key = VenuePlaces.canonicalKey(for: venue) else { return }
            // Strictly before today. A show tonight has not been shot yet.
            guard date < today else { return }
            titlesByVenueDate[key, default: [:]][date, default: []].append(title)
        }

        for shoot in shoots {
            record(venue: shoot.venue, date: shoot.date, title: shoot.title)
        }
        for booking in bookings {
            // A booking carries a date RANGE. Each of its days is a day Dan was in the room, and
            // expanding here is what lets a booking the calendar already holds collapse onto it
            // rather than sitting beside it as a second entry. `EasternDate.days` caps its own
            // range and returns just the start for a backwards one, so a malformed export cannot
            // explode into thousands of dates.
            for date in EasternDate.days(from: booking.startDate, through: booking.endDate) {
                record(venue: booking.venueName, date: date, title: booking.shootName)
            }
        }

        byVenue = titlesByVenueDate.mapValues { Self.absorbingRehearsals($0) }
    }

    // A dress rehearsal the night before its own performance is ONE engagement, not two.
    //
    // A date is dropped only when EVERY entry on it is rehearsal-marked AND a non-rehearsal entry
    // at the same venue sits within two days. Both halves matter. Measured across the whole live
    // store this changes exactly one venue (Abrons Arts Center, one opera's dress plus its
    // performance, 2 to 1), and the second half is what keeps The Players Theatre at 1: its only
    // event in eight years is a standalone dress rehearsal, and 31 live rows are at that room, so
    // dropping it would say nothing about a room Dan spent an evening shooting in.
    //
    // NOT a collapse of consecutive dates, which is the rule this replaced. The real calendar
    // kills that one: `[DCINY] Mozart's Messiah` and `[DCINY] A Winter's Light` are consecutive
    // nights and the same client but two different concerts, and Greenwich House Theater has two
    // DIFFERENT clients on consecutive nights.
    private static func absorbingRehearsals(_ titlesByDate: [String: [String]]) -> [Shoot] {
        let performanceDates = titlesByDate
            .filter { _, titles in titles.contains { !isRehearsal($0) } }
            .map(\.key)

        return titlesByDate
            .filter { date, titles in
                guard titles.allSatisfy({ isRehearsal($0) }) else { return true }
                return !performanceDates.contains { other in
                    guard let gap = EasternDate.daysUntil(from: date, to: other) else { return false }
                    return abs(gap) <= 2
                }
            }
            .map { Shoot(date: $0.key, titles: $0.value.sorted()) }
            .sorted { $0.date < $1.date }
    }

    // copy-inventory:ignore-start  Words MATCHED in Dan's own calendar titles, never shown to him (#1887)
    private static func isRehearsal(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return lowered.contains("rehearsal")
            || lowered.contains("sound check")
            || lowered.contains("soundcheck")
    }
    // copy-inventory:ignore-end

    // The band for a venue, or nil when there is nothing to say.
    //
    // Carnegie deliberately says NOTHING (Dan's call, 2026-07-31). The drafting rules already
    // require a Carnegie show to lead with the tenure credential, "nearly ten years at Carnegie
    // Hall", which is the same fact about the same room, and stacking a venue count beside it
    // would be #843's duplicate copy by construction. Settled in code rather than asked of the
    // drafter, so it cannot drift.
    func band(for venue: String?) -> Band? {
        guard let key = VenuePlaces.canonicalKey(for: venue) else { return nil }
        if let carnegie = Self.carnegieKey, key == carnegie { return nil }
        return Band.forCount(byVenue[key]?.count ?? 0)
    }

    // BOTH halves of the hybrid, composed in ONE place: the calendar backfill and Downbeat's own
    // bookings. Two callers need it (the prep queue writes the band onto each item, the review card
    // shows Dan what it will claim), and they must never disagree about what Dan has shot, so neither
    // composes it for itself.
    //
    // Reads two files, so callers build it ONCE per pass and never per row.
    static func current(today: String = EasternDate.today()) -> VenueShootHistory {
        VenueShootHistory(shoots: ShootHistory.loadWithHealth(now: Date()).shoots,
                          bookings: DownbeatBridge.loadedExport().bookings,
                          today: today)
    }

    // What is behind the band, for the review card. Without this, a wrong band and a right one
    // look identical to Dan, and this feature asserts a fact about him to a stranger with nothing
    // he can check it against.
    func shoots(for venue: String?) -> [Shoot] {
        guard let key = VenuePlaces.canonicalKey(for: venue) else { return [] }
        if let carnegie = Self.carnegieKey, key == carnegie { return [] }
        return byVenue[key] ?? []
    }
}
