import Testing
import Foundation
import SwiftData

// #1723 (milestone 34 Phase 5): the house list the app hands the Prep run, measured against Dan's real
// store rather than built rows. The unit suite (ProducerHouseListTests) proves the assembly rules; this
// proves the answers those rules actually produce on his 700-odd shows, which is where a rule that reads
// correctly can still be wrong about the data it meets.
//
// Gated on the live store existing, so a machine without one reports a visible SKIP rather than a silent
// pass. Reads a COPY, and copies the write-ahead log with it: reading the database file alone shows a
// stale snapshot (on 2026-07-29 the file said 701 shows and 19 cleared flags while the log said 696 and
// one), which would quietly pin verdicts against data that is not current.
@Suite("The house list, live store (#1723)")
struct HouseListLiveStoreTests {
    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    private func copyLiveStore(to dir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("Overture.store")
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: Self.liveStoreURL.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.copyItem(at: src, to: URL(fileURLWithPath: dest.path + suffix))
        }
        return dest
    }

    private func openContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema,
                                                                      url: url, cloudKitDatabase: .none)])
    }

    private func liveHouses() throws -> (houses: [ProducerGate.House], shows: [ProducerGate.Show],
                                         cleanup: () -> Void) {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("overture-1723-live-\(UUID().uuidString)", isDirectory: true)
        let storeCopy = try copyLiveStore(to: scratch)
        let ctx = ModelContext(try openContainer(at: storeCopy))
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let shows = all.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) }
        // Deliberately NO overrides. Dan's corrections are a separate, tested input (they travel through
        // ProducerOverrides and are pinned in the unit suite); pinning them here would make these verdicts
        // depend on what he happened to have corrected on the day.
        return (ProducerGate.houses(shows: shows), shows, { try? fm.removeItem(at: scratch) })
    }

    // LIVE-STORE-CLAIM verified=2026-07-29 measure="for each organisation named below, whether ProducerGate.houses puts it on the house list, computed over every prospect in the live store"
    // The eight verdicts this phase exists to pin, re-measured 2026-07-29 against 696 prospects (111
    // distinct venue keys, 118 houses). Each is a real organisation from the store, and each is here
    // because it exercises a DIFFERENT arm:
    //
    //   Carnegie Hall            a venue string outright
    //   Kaufman Music Center     named ONLY inside "Merkin Hall at Kaufman Music Center" (#1723)
    //   Abrons Arts Center       a venue string, and the #1681 show's own host
    //   Jalopy Theatre           a venue string, spelled three ways across the store
    //   Henry Street Settlement  named in a show's TITLE and nowhere else: the trail to follow, not a house
    //   Young New Yorkers' Chorus  a real producer, several churches, name in no venue string
    //   Fundacion Sinfonia       a real producer
    //   FRIGID New York          a house in fact, but named in no venue string, so only Dan can say so
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"), arguments: [
        ("Carnegie Hall", true),
        ("Kaufman Music Center", true),
        ("Abrons Arts Center", true),
        ("Jalopy Theatre", true),
        ("Henry Street Settlement", false),
        ("Young New Yorkers' Chorus", false),
        ("Fundacion Sinfonia", false),
        ("FRIGID New York", false),
    ])
    func theMeasuredVerdictsHold(_ organisation: String, _ expectedOnList: Bool) throws {
        let (houses, _, cleanup) = try liveHouses()
        defer { cleanup() }
        guard let key = ProducerGate.key(organisation) else {
            Issue.record("\(organisation) folds to no key at all")
            return
        }
        let onList = Set(houses.map(\.key)).contains(key)
        #expect(onList == expectedOnList,
                "\(organisation) (key \"\(key)\") should be \(expectedOnList ? "ON" : "off") the list")
    }

    // The one verdict that is not the store's to make. FRIGID rents one room to 40 companies, so it is a
    // house in every sense Dan cares about, but its name is in no venue string and it plays a single
    // room, so neither automatic arm can see it. His correction is the only thing that puts it on.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func frigidJoinsTheListOnlyWhenDanSaysSo() throws {
        let (houses, shows, cleanup) = try liveHouses()
        defer { cleanup() }
        let key = try #require(ProducerGate.key("FRIGID New York"))
        #expect(Set(houses.map(\.key)).contains(key) == false)

        let corrected = ProducerGate.houses(shows: shows,
                                            overrides: ProducerOverrides(demoted: [key]))
        #expect(Set(corrected.map(\.key)).contains(key))
    }

    // Not a fixed count, which moves daily as Dan triages and the scout runs, but the invariants that
    // must hold whatever the store holds. A list that lost its keys, or grew ones nothing folded to,
    // would pass every named verdict above while being broken for every organisation not named here.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theListIsWellFormedOnTheRealStore() throws {
        let (houses, shows, cleanup) = try liveHouses()
        defer { cleanup() }

        #expect(!houses.isEmpty, "the live store names houses")
        // Every key is genuinely folded, so an exact lookup can match it.
        for h in houses {
            #expect(h.key == ProducerGate.key(h.key), "\(h.key) is not in folded form")
            #expect(!h.name.isEmpty, "\(h.key) carries no readable name")
        }
        // One entry per key, so the run cannot meet the same house twice under two spellings.
        #expect(Set(houses.map(\.key)).count == houses.count)
        // Sorted, so the same store always writes the same queue file.
        #expect(houses.map(\.key) == houses.map(\.key).sorted())
        // Every venue in the store is a house. This is the arm Dan's standing rule depends on: a room's
        // own address is never a real contact, so no venue may be missing from the list.
        for venueKey in ProducerGate.venueKeys(of: shows) {
            #expect(Set(houses.map(\.key)).contains(venueKey), "venue \(venueKey) is not on the list")
        }
    }
}
