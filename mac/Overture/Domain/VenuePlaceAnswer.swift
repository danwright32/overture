import Foundation
import SwiftData

// #1752: where Dan says a room is, when Overture cannot work it out.
//
// `VenuePlaces` is a hand-seeded table, filled from the rooms the queue held on 2026-07-29. Every new
// room a watched source publishes with no city of its own needs an entry, and nothing anywhere said so:
// those shows simply carried "City not known" and the #970 geography gate could not judge them. The
// table went stale silently as the watchlist grew, which is exactly the path by which the gate becomes a
// no-op again, one venue at a time.
//
// LIVE-STORE-CLAIM verified=2026-08-07 measure="stored prospects with a blank location, and the distinct rooms they name"
// Measured before building this: 78 of 845 stored shows carry no location, across 18 distinct room
// spellings, and 56 of the 78 are ONE room, 54 Below, which the table has never heard of. That shape is
// the argument for an answer keyed on the ROOM rather than on the show: one sentence from Dan places
// fifty-six cards.
//
// Keyed on `VenuePlaces.canonicalKey`, the same identity the rest of the app uses for a room, so his
// answer for "54 Below" also reaches "54 Below, 254 W 54th St. Cellar, NYC 10019" and every other
// spelling of it a source invents. An independent entity with no relationship to Prospect, like
// PromotedProducer and DemotedHouse, so no re-key, merge or dismissal can ever take his answer with it.
@Model
final class VenuePlaceAnswer {
    // The room's identity. Unique at the STORE layer rather than merely in the code that writes it, so
    // two saves racing on one room cannot leave two answers that disagree.
    @Attribute(.unique) var venueKey: String

    // The spelling Dan was looking at when he answered, kept for display. The key is not readable and a
    // list of rooms has to name them in the words he saw on the card.
    var venueName: String

    // What he said: a city and state, in his own words, exactly as the source-row address box takes them.
    var location: String

    var answeredAt: Date

    init(venueKey: String, venueName: String, location: String, answeredAt: Date) {
        self.venueKey = venueKey
        self.venueName = venueName
        self.location = location
        self.answeredAt = answeredAt
    }
}

// The rooms Overture could not place, as an action list rather than a statistic.
//
// #1029 removed the sentence "N of M shows say where they are" because Dan did not find that framing
// useful ("I do not understand what that matters"), so this deliberately produces NAMED ROOMS he can
// answer, each carrying how many shows are waiting on it, and nothing that reads as a coverage score.
enum UnplacedRooms {
    struct Room: Equatable, Identifiable {
        var key: String
        var name: String        // the spelling to show him
        var showCount: Int
        var id: String { key }
    }

    // Cheap to evaluate on every redraw, unlike `from` itself, which walks every stored show and builds a
    // dictionary. The Sources sheet re-evaluates its body on every keystroke and every scroll tick, and
    // computing the list there directly is the defect #1356 and #1429 already fixed twice on this very
    // sheet (the coverage list, then the per-source tallies), each time after it froze the sheet.
    //
    // Combines only what the list can actually change on: how many shows there are, and for the unplaced
    // ones, which room they name. A row gaining a location drops out of the loop and moves the count, so a
    // fill is caught too.
    static func signature(_ prospects: [Prospect], today: String) -> Int {
        var acc = prospects.count
        for p in prospects where isWaiting(p, today: today) {
            var h = Hasher()
            h.combine(p.venue ?? "")
            acc = acc &+ h.finalize()
        }
        return acc
    }

    // Whether this show is one an answer would actually help: it has no location, it names a room, and it
    // HAS NOT ALREADY HAPPENED.
    //
    // That last clause was missing when this shipped, and walking the app is what found it: the panel read
    // "Denny Farrell Riverbank State Park, 2 shows waiting on this" while both of those shows were dated
    // June against an August clock. Nothing was waiting on that room. Left as it was, the list would
    // accumulate dead rooms forever and every count in it would drift upward, which is the opposite of the
    // action list #1029 asked for.
    //
    // Judged on the run's LAST date, so a run that opened last week and plays for another month still
    // counts. A show with NO date cannot be proved past and is kept: a room wrongly listed costs Dan one
    // glance, while a room wrongly dropped costs him the geography rule on every show in it, silently.
    private static func isWaiting(_ p: Prospect, today: String) -> Bool {
        guard (p.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let venue = p.venue?.trimmingCharacters(in: .whitespacesAndNewlines), !venue.isEmpty else {
            return false
        }
        guard let last = p.runEndDate ?? p.performanceDate, !last.isEmpty else { return true }
        return last >= today
    }

    // Every distinct room holding at least one show with no location, most shows first.
    //
    // A show with NO venue at all is excluded: there is no room to name, its card already reads
    // "Venue TBD", and listing it would ask a question with no answer. Ties break on the name so the
    // list is stable from one render to the next rather than dependent on fetch order.
    static func from(_ prospects: [Prospect], today: String) -> [Room] {
        var byKey: [String: (name: String, count: Int)] = [:]
        for p in prospects where isWaiting(p, today: today) {
            guard let venue = p.venue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let key = VenuePlaces.canonicalKey(for: venue) else { continue }
            // The SHORTEST spelling wins as the display name: sources append addresses and suite numbers
            // to one room ("54 Below" versus "54 Below, 254 W 54th St. Cellar, NYC 10019"), and the bare
            // name is both what Dan recognises and what he would type.
            let existing = byKey[key]
            let name = (existing.map { min($0.name.count, venue.count) == venue.count ? venue : $0.name }) ?? venue
            byKey[key] = (name, (existing?.count ?? 0) + 1)
        }
        return byKey
            .map { Room(key: $0.key, name: $0.value.name, showCount: $0.value.count) }
            .sorted { $0.showCount == $1.showCount ? $0.name < $1.name : $0.showCount > $1.showCount }
    }
}

// Recording an answer, and applying it in the same breath.
//
// Separate from the model so the rule (upsert on the room's identity, then place that room's blank
// shows, then report how many) is one testable function rather than something a view assembles.
enum VenuePlaceAnswering {
    // Returns how many shows took the answer, so the acknowledgement can say what actually happened
    // rather than promise a future read (the #1751 lesson, applied to the room ask as well).
    //
    // An empty answer WITHDRAWS the row rather than storing a blank one, so a table of answers never
    // holds an entry that says nothing. It does not un-place shows an earlier answer already reached:
    // the fill is additive everywhere else and a withdrawal that reached back into rows the scout has
    // since acted on would be a different, larger action than the one Dan took.
    @discardableResult
    static func record(venue: String, location: String, in context: ModelContext, now: Date) -> Int {
        guard let key = VenuePlaces.canonicalKey(for: venue) else { return 0 }
        let name = venue.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = ((try? context.fetch(FetchDescriptor<VenuePlaceAnswer>())) ?? [])
            .first { $0.venueKey == key }

        guard !place.isEmpty else {
            if let existing { context.delete(existing) }
            try? context.save()
            return 0
        }

        if let existing {
            existing.location = place
            existing.venueName = name
            existing.answeredAt = now
        } else {
            context.insert(VenuePlaceAnswer(venueKey: key, venueName: name,
                                            location: place, answeredAt: now))
        }
        let placed = LocationBackfill.run(in: context, onlyVenueKey: key)
        try? context.save()
        return placed
    }
}
