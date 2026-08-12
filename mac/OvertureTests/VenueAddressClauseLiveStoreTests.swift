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
@Suite("Address clauses in venue strings, measured on the real store (#2378, #1852)")
struct VenueAddressClauseLiveStoreTests {
    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath:
            StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false).path)
    }

    private func liveVenues() throws -> [String] {
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
        return Array(Set(rows.compactMap(\.venue).filter { !$0.isEmpty })).sorted()
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
}
