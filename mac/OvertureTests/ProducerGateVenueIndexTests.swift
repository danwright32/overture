import Testing
import Foundation
import SwiftData
@testable import Overture

// #1963, measured with `sample` against the live Release build on 2026-08-01: 846 of 14,856 main-thread
// samples landed in `ProducerGate.VenueBrands.init`, the single biggest slice inside `QueueModel.items`.
// Nearly all of it was the containment arm walking every presenter name against every venue key, roughly
// 400 by 114 on Dan's store, each pair a full string scan.
//
// The rule is unchanged. What changed is that a pair is only scanned when it could possibly match: a
// containment either way requires the two names to share a WORD, so the venue keys are indexed by their
// words and only the keys sharing one are compared.
//
// Two things have to be true for that to be a speed-up and not a behaviour change, and both are tested
// here rather than argued: the filter never drops a pair the rule would have matched, and the verdict is
// the same as the full cross product would have reached, on made-up names and on Dan's real store.
@Suite("The venue-brand scan is indexed, not a cross product (#1963)")
struct ProducerGateVenueIndexTests {

    // The rule as the full cross product expressed it: every venue key, both directions, no filtering.
    // The reference the indexed version has to agree with.
    private func fullScanSaysVenueBrand(_ presenterKey: String, venueKeys: Set<String>,
                                        overrides: ProducerOverrides = .none) -> Bool {
        if venueKeys.contains(presenterKey) { return true }
        if overrides.demoted.contains(presenterKey) { return true }
        if overrides.promoted.contains(presenterKey) { return false }
        return venueKeys.contains {
            ProducerGate.containsAsWords(presenterKey, $0) || ProducerGate.containsAsWords($0, presenterKey)
        }
    }

    // Real spellings from the live store, plus the cases the rule's own comments name as load-bearing.
    // "Carnegie Hall" is here in its own right because the venue key folds at the first comma, so the
    // Stern Auditorium spelling below never yields the words the containment arm needs.
    private let venues = [
        "Carnegie Hall",
        "Stern Auditorium / Perelman Stage, Carnegie Hall",
        "Weill Recital Hall at Carnegie Hall",
        "Zankel Hall, Carnegie Hall",
        "The Green Room 42",
        "SoHo Playhouse",
        "The Cell",
        "The Tank",
        "Bargemusic",
        "Merkin Hall",
        "Roulette Intermedium",
        "The Riverside Church",
        "David Geffen Hall",
    ]

    private let presenters = [
        "Carnegie Hall Presents",
        "Carnegie Hall Citywide",
        "Weill Recital Hall",
        // The room's name is not at the FRONT of this one. A filter that looked only at a name's first
        // word would drop it, and every other case here would still pass.
        "Friends of Merkin Hall",
        "The 52nd Street Project",
        "Think Tank Theatre",
        "The Cell",
        "Roulette Intermedium",
        "Bargemusic",
        "New York Philharmonic",
        "Spit&Vigor",
        "Riverside Church Music Series",
        "Aurora Strings",
        "Merkin Hall at Kaufman Music Center",
    ]

    private var venueKeys: Set<String> {
        Set(venues.compactMap { ProducerGate.key($0) })
    }

    private var presenterKeys: [String] {
        presenters.compactMap { ProducerGate.key($0) }
    }

    // The property the whole optimisation rests on: a pair the rule matches must survive the filter. If
    // this can fail, a house silently becomes a well travelled producer and Dan is offered its address.
    @Test func noPairTheRuleMatchesIsFilteredOut() {
        let keys = venueKeys
        let index = ProducerGate.VenueKeyIndex(keys)
        var matchedPairs = 0

        for presenter in presenterKeys {
            let candidates = index.candidates(for: presenter)
            for venue in keys {
                let matches = ProducerGate.containsAsWords(presenter, venue)
                    || ProducerGate.containsAsWords(venue, presenter)
                guard matches else { continue }
                matchedPairs += 1
                #expect(candidates.contains(venue),
                        "\(presenter) matches \(venue), so the filter must have offered it")
            }
        }

        // Without this the suite would pass just as well against a corpus where the rule matches nothing,
        // which would prove nothing at all.
        #expect(matchedPairs >= 4)
    }

    @Test func theIndexedVerdictAgreesWithTheFullScan() {
        let keys = venueKeys
        let index = ProducerGate.VenueKeyIndex(keys)
        for presenter in presenterKeys {
            #expect(ProducerGate.isVenueBrand(presenter, venues: index)
                    == fullScanSaysVenueBrand(presenter, venueKeys: keys),
                    "disagreed about \(presenter)")
        }
    }

    // And with Dan's corrections applied, since both arms read them and the promoted one is the arm the
    // filter sits behind.
    @Test func theIndexedVerdictAgreesWithTheFullScanUnderCorrections() {
        let keys = venueKeys
        let index = ProducerGate.VenueKeyIndex(keys)
        let overrides = ProducerOverrides(promoted: [ProducerGate.key("Carnegie Hall Presents") ?? ""],
                                          demoted: [ProducerGate.key("Aurora Strings") ?? ""])
        for presenter in presenterKeys {
            #expect(ProducerGate.isVenueBrand(presenter, venues: index, overrides: overrides)
                    == fullScanSaysVenueBrand(presenter, venueKeys: keys, overrides: overrides),
                    "disagreed about \(presenter)")
        }
    }

    // The speed-up itself, stated as a number rather than a hope: a presenter is compared against the
    // handful of rooms that share a word with it, not against every room in the store.
    @Test func aPresenterIsComparedAgainstAHandfulOfRoomsNotAllOfThem() {
        let keys = venueKeys
        let index = ProducerGate.VenueKeyIndex(keys)

        // Shares "hall" and "carnegie" with three Carnegie rooms, and "hall" with two others.
        let carnegie = ProducerGate.key("Carnegie Hall Presents") ?? ""
        #expect(index.candidates(for: carnegie).count < keys.count)
        // Shares no word with any room in the corpus, so nothing is compared at all.
        let unrelated = ProducerGate.key("Aurora Strings") ?? ""
        #expect(index.candidates(for: unrelated).isEmpty)
    }

    // The verdicts the rule's own comments call load-bearing, restated against the indexed path so a
    // filtering mistake cannot quietly change one.
    @Test func theNamedLiveCasesKeepTheirVerdicts() {
        let index = ProducerGate.VenueKeyIndex(venueKeys)

        // #1620: a house's own presenting brand IS the house. The presenter name CONTAINS the room's.
        #expect(ProducerGate.isVenueBrand(ProducerGate.key("Carnegie Hall Presents") ?? "", venues: index))
        // #1719, the reverse direction: the presenter's name sits INSIDE a venue string naming the room.
        #expect(ProducerGate.isVenueBrand(ProducerGate.key("Weill Recital Hall") ?? "", venues: index))
        // A single-word fold ("tank") must never swallow a real company that merely contains the word.
        #expect(!ProducerGate.isVenueBrand(ProducerGate.key("Think Tank Theatre") ?? "", venues: index))
        // An ordinary act is nobody's building.
        #expect(!ProducerGate.isVenueBrand(ProducerGate.key("Aurora Strings") ?? "", venues: index))
    }

    // A name spelled exactly like a room is still the room, which is the arm that runs before any
    // filtering happens at all.
    @Test func anExactRoomNameIsStillTheRoom() {
        let index = ProducerGate.VenueKeyIndex(venueKeys)
        #expect(ProducerGate.isVenueBrand(ProducerGate.key("Bargemusic") ?? "", venues: index))
        #expect(ProducerGate.VenueBrands(shows: [ProducerGate.Show(presenter: "Bargemusic", venue: "Bargemusic")])
                    .isRoomName("Bargemusic"))
    }

    // The set-taking entry point still exists for callers holding no index, and cannot drift from the
    // indexed one, since it builds one and asks it.
    @Test func theSetTakingEntryPointGivesTheSameAnswer() {
        let keys = venueKeys
        for presenter in presenterKeys {
            #expect(ProducerGate.isVenueBrand(presenter, venueKeys: keys)
                    == fullScanSaysVenueBrand(presenter, venueKeys: keys),
                    "disagreed about \(presenter)")
        }
    }
}

// The same parity question asked of the real thing. Made-up names cannot cover 400 presenter spellings
// and 114 room spellings, and this rule decides whether Dan is offered a house's address, so the indexed
// verdict is compared against the full cross product over every one of them.
@Suite("The indexed scan reaches the same verdicts on the live store (#1963)")
struct ProducerGateVenueIndexLiveStoreTests {
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

    // LIVE-STORE-CLAIM verified=2026-08-02 measure="distinct presenter and venue spellings in the store, and the venue-brand verdict each presenter gets from the full cross product against the indexed scan"
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func everyPresenterGetsTheSameVerdictAsTheFullCrossProduct() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-1963-live-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            let storeCopy = try copyLiveStore(to: scratch)
            let context = ModelContext(try openContainer(at: storeCopy))
            let all = try context.fetch(FetchDescriptor<Prospect>())
            let shows = all.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) }

            let venueKeys = ProducerGate.venueKeys(of: shows)
            let presenterKeys = Set(shows.compactMap { ProducerGate.key($0.presenter) })
            // The store still holds a real spread to measure, so a shrunken store cannot turn this into a
            // test of nothing.
            #expect(venueKeys.count > 50)
            #expect(presenterKeys.count > 100)

            let index = ProducerGate.VenueKeyIndex(venueKeys)
            var disagreements: [String] = []
            var brands = 0
            for presenter in presenterKeys {
                let indexed = ProducerGate.isVenueBrand(presenter, venues: index)
                let fullScan = venueKeys.contains(presenter) || venueKeys.contains {
                    ProducerGate.containsAsWords(presenter, $0) || ProducerGate.containsAsWords($0, presenter)
                }
                if indexed { brands += 1 }
                if indexed != fullScan { disagreements.append(presenter) }
            }

            #expect(disagreements.isEmpty, "the indexed scan disagreed on \(disagreements.prefix(5))")
            // The rule really is refusing names here, so the agreement above is not two empty answers.
            #expect(brands > 0)
        }
        await RealStoreTestLock.shared.release()
    }
}
