import Testing
import Foundation
import SwiftData

// #2378 and #1852, measured on the real store rather than on fixtures chosen to make the rule fire.
//
// Both issues asked for exactly this before shipping: #1852 says "measure any new test over every venue
// string in the store", and #2378 says a confidently wrong place is the one failure in this area that can
// HIDE a real show. So the change is judged on the rows it actually moves.
//
// Measured 2026-08-12 over all 144 distinct venue strings in the live store, by running the shipping
// functions themselves rather than a query written beside them (L107). Seven strings changed, every one an
// improvement:
//
//   placed, having been unplaceable
//     54 Below, 254 W 54th St. Cellar, NYC 10019                                    -> New York, NY
//     House of the Redeemer, Fabbri Mansion, 7 East 95th Street, Manhattan          -> Manhattan, NY
//     Peter Jay Sharp Theatre, 2537 Broadway at 95th St. New York, NY 10025-6990    -> New York, NY
//   placed more precisely than the curated table's "New York, NY"
//     Church of the Ascension, 127 Kent Street, Brooklyn                            -> Brooklyn, NY
//   address no longer printed on the card
//     Sakura Park, W 122nd St & Riverside Dr
//     Soldiers' and Sailors' Monument, Riverside Park (W. 89th St. & Riverside Drive), New York, NY
//   a WRONG place withdrawn
//     The Soldiers' and Sailors' Monument, on the North Patio, behind the monument. W. 89th St. &
//     Riverside Drive, in Riverside Park  ->  was read as "…, IN", which is Indiana. Now unplaced.
//
// Unplaced distinct venue strings: 33 of 144 before, 31 after, plus that one wrong answer withdrawn.
//
// These tests assert the RULES, not those counts: the counts move with every scout, the rules do not.
// Reads a copy of the live store and writes nothing anywhere.
// #2568 and #2566 measure the same way and about the same two text fields, so they live here rather
// than in a second suite that would take its own clone of the same store.
@Suite("Address clauses in venue and location strings, measured on the real store (#2378, #1852, #2568, #2566)")
struct VenueAddressClauseLiveStoreTests {
    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath:
            StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false).path)
    }

    private func liveVenues() throws -> [String] {
        try liveRows { $0.compactMap(\.venue) }
    }

    // #2566 reads the other text field the same way, so both come off one clone rather than two.
    private func liveLocations() throws -> [String] {
        try liveRows { $0.compactMap(\.location) }
    }

    private func liveRows(_ pick: ([Prospect]) -> [String]) throws -> [String] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("venue-address-\(UUID().uuidString)",
                                                               isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        guard let url = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let schema = Schema([Prospect.self, Recipient.self])
        let context = ModelContext(try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)]))
        let rows = try context.fetch(FetchDescriptor<Prospect>())
        return Array(Set(pick(rows).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
    }

    // LIVE-STORE-CLAIM verified=2026-08-12 measure="distinct venue strings whose card still carries an address clause, and whose city the string itself names"
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func noCardKeepsAStreetAddressAndNoStreetBecomesATown() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
        let venues = try liveVenues()
        #expect(venues.count > 50, "the live store still holds a real spread of venues to measure")

        // #1030's promise, asserted as a RULE over every string rather than as the count that was true
        // on the day: whatever a card ends up showing, none of its clauses may be an address.
        var cardsCarryingAnAddress: [String] = []
        for venue in venues {
            let card = VenueNormalization.strippingEmbeddedAddress(venue)
            let clauses = card.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            // The FIRST clause is the venue's own name and is never cut, so a room genuinely named for a
            // street ("Five Angels Theater at the 52nd Street Project") keeps its name. Everything after
            // it is a clause this rule chose to keep.
            if clauses.dropFirst().contains(where: { StreetClause.isAddress($0) }) {
                cardsCarryingAnAddress.append(card)
            }
        }
        #expect(cardsCarryingAnAddress.isEmpty,
                "these cards still print a street address: \(cardsCarryingAnAddress)")

        // The other direction, and the more dangerous one: a place this reads must never be a street.
        // Asserted by feeding every answer back through the address test that produced it.
        var streetsReadAsTowns: [String] = []
        for venue in venues {
            guard let place = EventLocationFill.cityFromVenue(venue) else { continue }
            let town = place.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? place
            if StreetClause.isAddress(town) || town.contains(where: \.isNumber) {
                streetsReadAsTowns.append("\(venue) -> \(place)")
            }
        }
        #expect(streetsReadAsTowns.isEmpty,
                "these venue strings placed a show on a street: \(streetsReadAsTowns)")
        // #2198: released INLINE on both paths. A `defer { Task { ... } }` hands the release to a task
        // that runs after the test has already returned, so the critical section is not exclusive.
        await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // The three rooms this change places, named individually because each is a string Dan has actually
    // been looking at. Skipped, not failed, if a room leaves the store: the rule is what is being pinned,
    // and a store that no longer holds the row cannot speak to it (a test that silently checks nothing
    // would be the worse outcome, so the count of rooms actually checked is asserted).
    // LIVE-STORE-CLAIM verified=2026-08-12 measure="the specific unplaceable rooms #2378 was filed on, re-read through the shipping rule"
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theRoomsTheIssueWasFiledOnNowPlace() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
        let venues = Set(try liveVenues())
        let expected = [
            "Peter Jay Sharp Theatre, 2537 Broadway at 95th St. New York, NY 10025-6990": "New York, NY",
            "54 Below, 254 W 54th St. Cellar, NYC 10019": "New York, NY",
            "House of the Redeemer, Fabbri Mansion, 7 East 95th Street, Manhattan": "Manhattan, NY",
        ]
        var checked = 0
        for (venue, place) in expected where venues.contains(venue) {
            #expect(EventLocationFill.cityFromVenue(venue) == place, "\(venue) did not place as \(place)")
            checked += 1
        }
        #expect(checked > 0,
                "none of the rooms #2378 was filed on are in the store any more, so this checked nothing")
        await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // #2568, as a RULE rather than as the one word it was found on: a room's own NAME is never a
    // statement about where the room is, so replacing it must not move the show. Asserted by rewriting
    // the first clause of every live venue string and re-reading it, which is the only way to tell a
    // place read out of the address from one read out of the name.
    //
    // LIVE-STORE-CLAIM verified=2026-08-16 measure="distinct venue strings whose place changes when the room's own name clause is replaced"
    // Measured before the fix over all 144 distinct venue strings: exactly ONE moved, and it is the row
    // the issue was filed on. `Rosewood Hotel Georgia, Vancouver, BC, Canada` answered `Rosewood Hotel,
    // Georgia` and answered nothing at all once renamed.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func replacingARoomsOwnNameNeverMovesTheRoom() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
        let venues = try liveVenues()
        #expect(venues.count > 50, "the live store still holds a real spread of venues to measure")

        var moved: [String] = []
        var readable = 0
        for venue in venues {
            guard let comma = venue.firstIndex(of: ",") else { continue }
            let renamed = "A Room" + String(venue[comma...])
            let asWritten = EventLocationFill.cityFromVenue(venue)
            if asWritten != nil { readable += 1 }
            if asWritten != EventLocationFill.cityFromVenue(renamed) {
                moved.append("\(venue) -> \(asWritten ?? "nothing"), "
                    + "renamed -> \(EventLocationFill.cityFromVenue(renamed) ?? "nothing")")
            }
        }
        // Zero strings read as a place would satisfy the check above while proving nothing (L98), and
        // the whole rule is about strings this DOES read.
        #expect(readable > 10, "only \(readable) live venue strings named a place, so this checked little")
        #expect(moved.isEmpty, "these rooms are placed by their own NAME: \(moved)")
        await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // #2566's blast radius, as a rule. Refusing a published location is only safe while the refusal
    // leaves alone the locations that already place a show, and most of the store's addresses do place
    // one: 13 of the 15 distinct address-carrying locations name their city perfectly well, and they
    // cover 279 of the 892 placed rows. A refusal that fired on those would unplace a third of the queue
    // (L93), and it would look exactly like a careful fix while doing it.
    //
    // LIVE-STORE-CLAIM verified=2026-08-16 measure="distinct stored locations the geography gate places IN range, and whether the fill still stores each one"
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func refusingAPublishedLocationNeverThrowsAwayOneThatPlacesAShow() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
        let locations = try liveLocations()
        #expect(locations.count > 20, "the live store still holds a real spread of locations to measure")

        var dropped: [String] = []
        var placed = 0
        for location in locations
        where EventPlace.resolve(location: location, discipline: .theater).verdict == .inRange {
            placed += 1
            if EventLocationFill.location(title: "A Show", venue: nil, published: location) != location {
                dropped.append(location)
            }
        }
        #expect(placed > 10, "only \(placed) live locations placed a show, so this checked little")
        #expect(dropped.isEmpty, "these locations place a show and are no longer stored: \(dropped)")
        await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // #3314: the test that stood here read the SPECIFIC rows #2568 and #2566 were filed on, by their
    // exact venue and location strings, and skipped any that had left the store. It carried
    // `#expect(checked > 0)` so it could never quietly check nothing, and on 2026-08-30 that assertion
    // fired: all three of its subjects are gone from Dan's store.
    //
    // That is the guard working, not a defect, and the honest answer to it is retirement rather than a
    // looser assertion. A test pinned to particular live rows has a premise that expires the day those
    // rows are cleared, and re-pinning it to whatever is in the store today would only move the expiry.
    //
    // What it was FOR is untouched, which is the half worth stating so its absence is not read as
    // coverage lost (L129). `EventLocationFillTests` asserts all three rules on the same three strings,
    // verbatim: "Rosewood Hotel Georgia, Vancouver, BC, Canada" resolving to Vancouver rather than to
    // Georgia (#2568), and the two described rooms being refused rather than standing in for a place
    // (#2566). Those are synthetic and cannot expire. The two live-store tests ABOVE are also untouched
    // and still measure the rules against whatever is really in the store, which is the part a live
    // corpus is uniquely good for; what has gone is only the pinning to three named rows.
}
