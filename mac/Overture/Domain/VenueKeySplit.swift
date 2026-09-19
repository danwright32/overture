import Foundation

// #1899: does the Shoots calendar and Downbeat's export name each room the same way?
//
// `VenueShootHistory` unions the two on (venue key, Eastern date). That was only ever verified against
// bookings Downbeat itself wrote onto the calendar, so one program produced both spellings and they could
// not disagree. The roughly 320 events Dan typed by hand are what a future Downbeat booking has to agree
// with. If the two fold to DIFFERENT keys, the room's history splits: each half is reachable only by the
// spelling a prospect happens to carry, the pitch understates how well Dan knows the room, and nothing
// anywhere reported it.
//
// THE SIGNATURE, which is narrower than "a Downbeat venue no calendar shoot uses" on purpose. That alone
// is also what every genuinely new room looks like, and saying so about each one would be a line that
// cries wolf on Dan's best news. The split shows when the calendar holds a shoot on the SAME NIGHT under
// another key: Downbeat writes its bookings onto that calendar, so one night appearing under two keys is
// one room named two ways. A key the calendar already uses anywhere is never a split, since the union
// already joins it.
//
// Pure, over the two lists the union itself reads, so the check and the count cannot disagree about what
// either source said.
enum VenueKeySplit {
    struct Split: Equatable, Hashable, Sendable {
        var downbeatVenue: String   // as Downbeat's export names the room
        var calendarVenue: String   // as the Shoots calendar names it on the same night
        var date: String            // the night both hold, which is the evidence they are one room
    }

    static func find(shoots: [ShootRecord], bookings: [OvertureBooking]) -> [Split] {
        var calendarKeys: Set<String> = []
        var calendarByDate: [String: [(venue: String, key: String)]] = [:]
        for shoot in shoots {
            guard let key = VenuePlaces.canonicalKey(for: shoot.venue) else { continue }
            calendarKeys.insert(key)
            calendarByDate[shoot.date, default: []].append((shoot.venue, key))
        }

        var reported: Set<[String]> = []
        var splits: [Split] = []
        for booking in bookings {
            guard let key = VenuePlaces.canonicalKey(for: booking.venueName),
                  !calendarKeys.contains(key) else { continue }
            // Every day of the booking, exactly as the union expands it.
            for date in EasternDate.days(from: booking.startDate, through: booking.endDate) {
                for other in calendarByDate[date] ?? [] where other.key != key {
                    // One finding per pair of keys, however many nights it recurs on.
                    guard reported.insert([key, other.key]).inserted else { continue }
                    splits.append(Split(downbeatVenue: booking.venueName, calendarVenue: other.venue,
                                        date: date))
                }
            }
        }
        return splits.sorted { ($0.date, $0.downbeatVenue) < ($1.date, $1.downbeatVenue) }
    }

    // Both files, read the way the union reads them. Called once at launch and on each re-read, never per
    // render: it decodes two JSON files.
    static func current() -> [Split] {
        find(shoots: ShootHistory.loadWithHealth(now: Date()).shoots,
             bookings: DownbeatBridge.loadedExport().bookings)
    }

    // A calendar venue can carry its address on extra lines and arrive wrapped in quotes (see
    // `ShootRecord`). For a sentence, the first line without the quotes is the room's name.
    static func displayName(_ raw: String) -> String {
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        return firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespaces))
    }
}
