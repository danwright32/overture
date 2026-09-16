import Testing
import Foundation

// #3656: the Sources sheet no longer decides whether to redraw a number by HASHING the store.
//
// WHY THIS IS A CORRECTNESS CHANGE AND NOT A SPEED ONE. `SourceYield.signature`'s own docstring recorded
// the property that made it acceptable: "A hash collision can only mean one stale redraw, never a wrong
// number". That is the only place in milestone #80 where a screen can genuinely disagree with the store,
// and Dan has ruled that out. `UnplacedRooms.signature` had the same shape and the same property.
//
// WHAT IT COST, measured before it was done rather than after (`SourcesSheetCostTests`, 2026-09-08, over
// 1,226 prospects): the two change-keys cost 3.95 ms and 2.46 ms per body evaluation to avoid recomputes
// of 6.21 ms and 2.64 ms. So the `UnplacedRooms` gate was saving about 7% and `SourceYield`'s about 36%,
// and removing both costs roughly 2.44 ms per redraw. Dan's call, 2026-09-08, with those numbers in
// front of him: drop both and take the 2.44 ms.
//
// `ClientCoverage`'s gate STAYS, and that is not an inconsistency. It costs 0.47 ms and it guards an
// O(clients x sources) fuzzy match, which is the shape a gate is actually for. It is recorded below by
// name so the exemption is a decision somebody made rather than a case the scan happened to miss (L233).
@Suite("The Sources sheet does not gate a redraw on a hash of the store (#3656)")
struct SourcesSheetHasNoStaleCacheTests {
    private static var view: String { SourceGuardHelper.source("Overture/UI/SourcesView.swift") }

    /// The gates that may remain, each because somebody read it and decided it earns its place.
    private static let recordedSignatureGates: Set<String> = ["ClientCoverage"]

    @Test func onlyTheRecordedSignatureGatesRemain() {
        // Derived from the source rather than listed, so a NEW gate joins the check on its own (L96).
        let found = Set(Self.view
            .components(separatedBy: ".onChange(of: ")
            .dropFirst()
            .compactMap { chunk -> String? in
                guard let dot = chunk.firstIndex(of: "."),
                      chunk[chunk.index(after: dot)...].hasPrefix("signature(") else { return nil }
                return String(chunk[chunk.startIndex..<dot])
            })
        #expect(found == Self.recordedSignatureGates,
                Comment(rawValue: """
                    SourcesView gates a redraw on \(found.sorted()) against a recorded \
                    \(Self.recordedSignatureGates.sorted()). A change-key built by hashing a store \
                    collection can collide, and a collision means the sheet draws a number the store \
                    disagrees with. Dan has ruled that out. If a new gate genuinely earns its place, \
                    read it, say what it guards and how much it saves, and record it here.
                    """))
    }

    /// And the recompute that replaced the gate is paid ONCE per body evaluation, never per row.
    ///
    /// This is the guard that matters most, because the obvious conversion reintroduces #1429 exactly:
    /// `tallies` was read inside `row(_:)`, so a plain computed property would run the whole-store scan
    /// once per source row. Measured 2026-09-08 that is 6.21 ms x 73 rows, which is 453 ms of main
    /// thread on a scroll, and it is the very defect the cache was built to fix (L62: a guard on a
    /// function's first line cannot protect against the cost of building its arguments).
    @Test func theWholeStoreScansAreNotInThePerRowPath() throws {
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "row", in: Self.view),
                                "SourcesView.row(_:) is gone, so this guard is standing over nothing")
        // #3645: the render PASS joins the list, because the same mistake is now one call away. A
        // `SourcesRenderPass.make(` inside `row(_:)` would run both scans below once per source row, and
        // it reads as the tidier spelling of exactly the defect this guard exists for.
        for scan in ["SourceYield.tallies(", "UnplacedRooms.from(", "SourcesRenderPass.make("] {
            #expect(!body.contains(scan),
                    Comment(rawValue: "row(_:) calls \(scan), so the whole-store scan runs once per "
                            + "source row rather than once per body evaluation. That is #1429 exactly, "
                            + "and it is what froze this sheet."))
        }
    }

    /// The retired signatures are DELETED, not left beside their replacement with the justification
    /// rewritten, which is how a codebase ends up half converted with the old thing arguing for itself
    /// (L29, L613).
    @Test func theRetiredSignaturesAreGone() {
        for (file, symbol) in [("Overture/Domain/SourceYield.swift", "static func signature"),
                               ("Overture/Domain/VenuePlaceAnswer.swift", "static func signature")] {
            // The predicate is reduced to a Bool BEFORE `#expect` sees it. Written
            // `#expect(!source.contains(symbol))` the expectation renders its operands on failure, and one
            // of them is the whole file: the real message then sits under a wall of source and the
            // reader cannot find it (L351, L148).
            let stillDeclared = SourceGuardHelper.source(file).contains(symbol)
            #expect(stillDeclared == false,
                    Comment(rawValue: "\(file) still declares `\(symbol)`. It has no caller now, and a "
                            + "retired rule kept with its docstring is a decision nobody revisits (L346)."))
        }
    }
}
