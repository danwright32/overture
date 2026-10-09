import Testing
import Foundation
import SwiftData

// #4623: the engine hands its pass the shows in ONE declared order (natural key in byte order, then the store
// identifier, L343), and putting them in that order is the one step the switch added to every queue pass.
//
// Measured 2026-10-08 on the live clone (`PassCostByTermProbeTests`): sorting the retained rows themselves cost
// 46.9 ms of a 269.4 ms pass at 1x and 229.8 ms of 1,316.2 ms at 4x in an optimised build, and 96.4 ms and 424.1 ms
// in Debug, where the pass over facts was otherwise faster than the pass over models. A `RowFacts` carries every
// stored field of a show, so every move the sort made copied all of them, while the order is decided by two. So
// the order is decided over the keys alone and each row is copied into its place once.
private struct OlderThanMacOS15: Error, CustomStringConvertible {
    var description: String { "this fixture mints identifiers with an API macOS 15 added" }
}

@Suite("The engine puts its shows in byte order of key, then identifier, without sorting the rows themselves (#4623)")
@MainActor
struct QueueEngineShowOrderTests {

    /// The engine's store holding one show per key: one saved show with every field written as `FactsFixture`
    /// writes it, extracted once per key with its natural key set to that key, each under an identifier of its
    /// own. Built from one saved row rather than one per key, because saving 1,500 populated shows took the
    /// fixture twenty minutes in Debug (measured 2026-10-08), and the natural key is unique in the store anyway.
    private static func store(keys: [String]) throws -> (FactStore, ModelContainer) {
        // An identifier of the fixture's own needs the store's identifier constructor, which macOS 15 added; the app's
        // deployment target is older, so an older Mac says why rather than passing with nothing built.
        guard #available(macOS 15, *) else { throw OlderThanMacOS15() }
        let container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        let (show, _, _) = try FactsFixture.liveRow(variant: 1, in: container.mainContext)
        var facts = FactStore()
        for (i, key) in keys.enumerated() {
            show.naturalKey = key
            let id = try PersistentIdentifier.identifier(for: "show-order", entityName: "Prospect", primaryKey: i)
            facts.shows[id] = RowFacts.extract(show)
        }
        return (facts, container)
    }

    @Test func theShowsComeInByteOrderOfKey() throws {
        // "B" before "a" (0x42 against 0x61), and a decomposed accent before the precomposed one (0x65 against
        // 0xC3), which String's own `<` calls equal, so only a comparison of the bytes orders the two.
        let (facts, container) = try Self.store(keys: ["b", "\u{e9}", "a", "e\u{301}", "B", "ab"])
        #expect(QueueEngineQueue.shows(facts).map(\.naturalKey) == ["B", "a", "ab", "b", "e\u{301}", "\u{e9}"],
                "the shows are not in byte order of their natural key")
        withExtendedLifetime(container) {}
    }

    // Judged against copying every row once, measured in the same run (L224), which is the least any ordering of
    // the rows can cost, since the ordered list holds a copy of each. Measured in Debug 2026-10-09 over these 1,500
    // rows: sorting the rows themselves 75.5 ms against 1.1 ms (66.8 times), and ordered over the keys 12.2 ms
    // against 1.1 ms (10.8 times). The ceiling sits between the two, far from both (L172); the readings are printed.
    @Test func orderingTheShowsCostsAFewCopiesOfEachRowNotASortOfThem() throws {
        let keys = (0..<1500).map { "\(($0 * 7919) % 1500) a show at a venue somewhere in the city" }
        let (facts, container) = try Self.store(keys: keys)
        try #require(facts.shows.count == keys.count, "the fixture did not hold a row for every key")
        let arms = Phase0.alternating([
            ("showorder-ordered", { _ = QueueEngineQueue.shows(facts) }),
            ("showorder-copiedOnce", { _ = Array(facts.shows.values) }),
        ])
        let (ordered, copied) = (arms[0], arms[1])
        print(String(format: "show order over %d rows: ordered %.1f ms, every row copied once %.1f ms (%.1fx)",
                     keys.count, ordered.median, copied.median, ordered.median / max(copied.median, 0.001)))
        #expect(ordered.median < copied.median * 25,
                Comment(rawValue: String(format: "putting the shows in order costs %.1f ms against %.1f ms for "
                                         + "copying each row once", ordered.median, copied.median)))
        withExtendedLifetime(container) {}
    }
}
