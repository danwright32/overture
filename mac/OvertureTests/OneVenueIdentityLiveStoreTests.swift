import Testing
import Foundation
import SwiftData

// #1802: seven issues were one cause wearing different clothes. A venue's name was folded into a key by
// more than one code path, and its city was derived separately from its name, which produced duplicate
// cards for one room (#1761), 131 cards claiming the city was unknown while the app held it (#1762), one
// night stored as three rows with three paid contact answers (#1764), 163 cards naming their own room as
// the presenter (#1795), and an address typed on a source row that never reached the shows already in the
// queue (#1751, #1752).
//
// Each had been fixed in isolation before, and a fix to one silently re-broke another, because the folds
// were parallel rather than shared. So the closing condition #1802 set for itself was never "the seven are
// fixed" but "the seven are MEASURED TOGETHER, on the real store, after one shared identity landed".
//
// This is that measurement, kept rather than run once, so the symptoms cannot come back one at a time
// while every issue behind them reads closed. Each expectation below is the invariant, not the count that
// happened to be true on the day: the counts move with every scout, the rules do not.
//
// Reads a copy of the live store and writes nothing anywhere.
@Suite("One venue identity, measured on the real store (#1802)")
// #3065: `final class` so the sandbox goes with each test. These held a whole clone of the live store,
// about 4 MB each, which is why 56 of them accounted for 1.62 GB when the issue was measured.
final class OneVenueIdentityLiveStoreTests {
    private let sandboxes = TemporarySandboxes()

    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath:
            StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false).path)
    }

    private func liveProspects() throws -> [Prospect] {
        let dir = try sandboxes.make(named: "venue-identity")
        guard let url = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let schema = Schema([Prospect.self, Recipient.self])
        let context = ModelContext(try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)]))
        return try context.fetch(FetchDescriptor<Prospect>())
    }

    // LIVE-STORE-CLAIM verified=2026-08-07 measure="the seven venue-identity symptoms, re-counted together on the real store"
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theSevenSymptomsAreMeasuredTogether() async throws {
        await RealStoreTestLock.shared.acquire()
        // #2198: released INLINE on both paths, never from a Task. A `defer { Task { ... } }` hands
        // the release to an unstructured task that runs after the test has already returned, so the
        // critical section is not exclusive at all. That is #2190: the process died partway and three
        // consecutive runs each blamed a different innocent test while 600 to 1,500 tests silently
        // never ran (#2195).
        do {

            let all = try liveProspects()
            #expect(all.count > 100, "the live store still holds a real queue to measure")
            let live = all.filter { $0.status != .dismissed }

            // #1795: a room standing in as its own show's presenter. `RoomPresenterSweep` runs every launch and
            // is idempotent by construction, so a row in this state can only be one written since the last
            // launch, which is a claim about the boundary guard rather than about the sweep.
            let roomAsPresenter = live.filter { p in
                guard let named = p.presenter, !named.isEmpty else { return false }
                let asRead = ExtractedEvent(title: p.groupName, presenter: named, venue: p.venue)
                return ExtractedEventGuard.presenterThatIsNotTheRoom(asRead).presenter == nil
            }
            #expect(roomAsPresenter.isEmpty,
                    "#1795: \(roomAsPresenter.count) row(s) still name their own room as the presenter: \(roomAsPresenter.prefix(3).map(\.groupName))")

            // #1762: a card saying the city is unknown for a room the app can place. The queue's own table is
            // the authority, so a blank location on a row whose venue the table knows is the app failing to
            // apply what it already holds.
            let placeableButBlank = live.filter { p in
                (p.location ?? "").isEmpty && VenuePlaces.location(for: p.venue) != nil
            }
            #expect(placeableButBlank.isEmpty,
                    "#1762: \(placeableButBlank.count) row(s) have no city while the venue table holds one: \(placeableButBlank.prefix(3).map { "\($0.groupName) [\($0.venue ?? "-")]" })")

            // #1761 / #1764: one room spelled two ways, minting a second card for the same night. Judged
            // through the SHARED identity (`VenuePlaces.canonicalKey`), which is the whole point of the issue:
            // two rows that are one show must collide on it.
            var seen: [String: [Prospect]] = [:]
            for p in live {
                guard let date = p.performanceDate, !date.isEmpty else { continue }
                let venueKey = VenuePlaces.canonicalKey(for: p.venue) ?? "unplaced"
                let titleKey = TitleNormalization.normalizeForKey(p.groupName)
                seen["\(titleKey)|\(date)|\(venueKey)", default: []].append(p)
            }
            let duplicates = seen.filter { $0.value.count > 1 }
            #expect(duplicates.isEmpty,
                    "#1761/#1764: \(duplicates.count) show(s) are stored more than once under one identity: \(duplicates.keys.sorted().prefix(3))")
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // The other half of #1802, and the one a count cannot show: that there is ONE fold. A second spelling
    // of the same question is how these symptoms came back last time, so the identity every rule uses is
    // asserted to agree with itself across the spellings the store really holds.
    @Test func oneIdentityAnswersForEverySpellingOfARoom() {
        let spellings = [
            ["Carnegie Hall", "Carnegie Hall, 881 Seventh Avenue", "carnegie hall"],
            ["The Green Room 42", "The Green Room 42, 570 Tenth Avenue", "Green Room 42"],
            ["54 Below", "54 Below, 254 W 54th St. Cellar, NYC 10019", "54 Below, New York, NY"],
        ]
        for group in spellings {
            let keys = Set(group.map { VenuePlaces.canonicalKey(for: $0) ?? "nil" })
            #expect(keys.count == 1,
                    "one room resolved to \(keys.count) identities: \(group) -> \(keys.sorted())")
        }
    }
}
