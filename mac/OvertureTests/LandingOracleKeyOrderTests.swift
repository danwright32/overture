import Testing
import Foundation
import SwiftData

// #4518: the order the landing oracle's real arm hands the landing its stored shows in IS the order today's
// landing holds its table in.
//
// The real arm's recording is made at 6d3453d8, which took the stored shows in whatever order an unsorted fetch
// returned them, and on a context holding unsaved changes that order moves from one read to the next (#4397). So
// the real arm passes the landing a read that returns them in natural key order (`LandingOracle.inKeyOrder`), on
// both sides of the comparison, which makes the recording the store 6d3453d8 leaves given the order the landing
// uses today (`Prospect.inKeyOrder`, #4407). That only holds while the two orders are ONE order. They cannot be one
// function: the oracle's files are overlaid onto 6d3453d8, which has no `Prospect.inKeyOrder`, so the oracle keeps
// its own copy. This holds the copy to the app's answer, and lives outside the overlay because it names the app's.
@MainActor
@Suite("The landing oracle pins the order today's landing holds its table in (#4518)")
struct LandingOracleKeyOrderTests {

    private static func stored(_ key: String) -> Prospect {
        Prospect(naturalKey: key, groupName: "Show \(key)", discipline: "music", venue: "Larkspur Hall",
                 performanceDate: "2026-11-01", sourceListingURL: "https://order.example/\(key)",
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                 possibleMatchSource: nil, possibleMatchName: nil)
    }

    // Keys where byte order and the String comparison disagree: an accent written decomposed sorts before "f" in
    // bytes and after it as a String, and the same word composed and decomposed are two keys in bytes and EQUAL as
    // Strings. Plus one key held twice, which must keep the order it was handed in.
    static let keys = ["fern|2026-11-01|hall", "e\u{301}clat|2026-11-01|hall", "\u{E9}clat|2026-11-01|hall",
                       "aster|2026-11-01|hall", "aster|2026-11-01|hall", "Zinnia|2026-11-02|hall"]

    @Test(arguments: [false, true])
    func theOraclesOrderIsTheLandingsOrder(reversed: Bool) {
        let rows = (reversed ? Array(Self.keys.reversed()) : Self.keys).map(Self.stored)
        let oracle = LandingOracle.inKeyOrder(rows).map(ObjectIdentifier.init)
        let app = Prospect.inKeyOrder(rows).map(ObjectIdentifier.init)
        #expect(oracle == app, Comment(rawValue:
            "the real arm hands the landing its shows in \(LandingOracle.inKeyOrder(rows).map(\.naturalKey)), and "
            + "today's landing holds them in \(Prospect.inKeyOrder(rows).map(\.naturalKey))"))

        // The positive control (L159): the fixture separates byte order from the String comparison, so an
        // oracle sorting by the latter would be told apart here rather than agreeing by accident.
        let byString = rows.enumerated().sorted {
            $0.element.naturalKey == $1.element.naturalKey ? $0.offset < $1.offset
                : $0.element.naturalKey < $1.element.naturalKey
        }.map { ObjectIdentifier($0.element) }
        #expect(byString != app, Comment(rawValue:
            "the fixture's keys sort the same by String comparison as by bytes, so it cannot tell the two apart"))
    }
}
