import Testing
import Foundation

// #4329 / #4370: the rule `StoreWriteScan` applies, driven over small sources the test writes itself, so what
// it derives (the model vocabulary, the calls it follows, the writes it finds) is pinned apart from any one
// question asked of the app. A12 asks it about the scout's read phase (`ScoutReadPhaseWriteScanTests`), and
// B1 will ask it about the whole landing; both stand on this behaving as stated here.
@Suite("The store write scan derives what it claims to (#4329, #4370)")
struct StoreWriteScanTests {

    private static func scan(_ files: [(name: String, text: String)],
                             stored: [String: Set<String>] = ["Row": ["count", "label", "rawState"]],
                             entry: String = "run", owner: String = "Runner") throws -> [String] {
        let index = StoreWriteScan.Index(files: files)
        let vocabulary = StoreWriteScan.vocabulary(stored: stored, index: index)
        return try StoreWriteScan.writesReachable(fromRegionOf: entry, owner: owner, endingBefore: "begin(",
                                                  index: index, vocabulary: vocabulary).sites.map(\.key)
    }

    private static let model = """
        @Model
        final class Row {
            var count: Int = 0
            var label: String = ""
            var rawState: String = ""
            var state: String {
                get { rawState }
                set { rawState = newValue }
            }
            var shout: String { label.uppercased() }
            func bump() { count += 1 }
            func bumpTwice() { bump(); bump() }
            func describe(prefix: String = "") -> String { prefix + label }
        }
        """

    // The vocabulary comes from the model: its stored properties, a computed one whose setter writes one of
    // them, and the methods that write the row, directly or through another (to a fixed point). A read only
    // computed property and a read only method are neither.
    @Test func theVocabularyIsDerivedFromTheModel() {
        let index = StoreWriteScan.Index(files: [("Row.swift", Self.model)])
        let vocabulary = StoreWriteScan.vocabulary(stored: ["Row": ["count", "label", "rawState"]], index: index)
        #expect(vocabulary.properties == ["count", "label", "rawState", "state"])
        #expect(vocabulary.mutators == ["bump", "bumpTwice"])
        #expect(vocabulary.entities(owning: "bumpTwice") == ["Row"])
    }

    @Test func theScanFindsEachShapeOfStoreWrite() throws {
        let runner = """
            enum Runner {
                static func run(row: Row, context: ModelContext) async {
                    row.label = "x"
                    row.state = "y"
                    row.bumpTwice()
                    _ = row.describe()
                    context.insert(row)
                    context.delete(row)
                    try? context.save()
                    Helper.work(row)
                    local(row)
                    let token = await flight.begin()
                    row.count = 9
                }
                private static func local(_ row: Row) { row.count -= 1 }
            }
            """
        let helper = """
            enum Helper {
                static func work(_ row: Row) { row.bump() }
            }
            """
        let keys = try Self.scan([("Row.swift", Self.model), ("Runner.swift", runner), ("Helper.swift", helper)])
        #expect(Set(keys) == [
            "Runner.run assigns label",
            "Runner.run assigns state",               // a computed property whose setter writes a stored one
            "Runner.run calls mutator bumpTwice",     // a mutator through another mutator
            "Runner.run inserts",
            "Runner.run deletes",
            "Runner.run saves",
            "Helper.work calls mutator bump",         // across files, by a qualified call
            "Runner.local assigns count",             // a bare call to the type's own function
        ], Comment(rawValue: "found \(keys)"))
        // `row.count = 9` sits after the boundary, so it is the landing's, never the region's.
        #expect(!keys.contains("Runner.run assigns count"))
    }

    @Test func aRegionWithNoBoundaryIsRefusedRatherThanScannedWhole() {
        let runner = """
            enum Runner {
                static func run(row: Row) { row.label = "x" }
            }
            """
        #expect(throws: StoreWriteScan.Refusal.self) {
            _ = try Self.scan([("Row.swift", Self.model), ("Runner.swift", runner)])
        }
    }

    @Test func aMissingEntryIsRefused() {
        #expect(throws: StoreWriteScan.Refusal.self) {
            _ = try Self.scan([("Row.swift", Self.model)], entry: "absent")
        }
    }

    // A default closure in a long signature is not mistaken for the body, and the declaration line is not
    // read as the function calling itself (which would pull in everything after the boundary).
    @Test func aSignatureIsNotTheBody() throws {
        let runner = """
            enum Runner {
                static func run(row: Row,
                                hook: () -> Void = { },
                                other: Int = 1) async {
                    _ = row.describe()
                    let t = await flight.begin()
                    row.label = "after"
                }
            }
            """
        #expect(try Self.scan([("Row.swift", Self.model), ("Runner.swift", runner)]).isEmpty)
    }
}
