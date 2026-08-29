import Testing
import Foundation

// #1916: `probeSelection` refuses on its first two lines unless Dan is on Scout with dates ticked, which
// is almost never. That guard reads like it makes the call cheap. It does not: the rows handed to it are
// an ARGUMENT, and arguments are evaluated before the call, so the queue swept every one of its 724 shows
// to feed a function that returned nil immediately, on every render pass and every stage.
//
// The rule stays in one place (inside this function, where it is tested) and the laziness is structural:
// the rows arrive as something the function can decline to evaluate. These pin that it declines.
@Suite("A refused probe selection never builds its rows (#1916)")
struct ProbeSelectionSkipsItsRowBuildTests {
    // Stands in for `scoutRows`, the whole-store sweep the real call site passes in.
    private final class RowSource {
        private(set) var builds = 0
        private let items: [QueueItem]
        init(_ items: [QueueItem]) { self.items = items }
        func rows() -> [QueueItem] {
            builds += 1
            return items
        }
    }

    private func item(_ key: String) -> QueueItem {
        QueueItem(id: key, groupName: key, discipline: "music", venue: "Weill Recital Hall",
                  performanceDate: "2026-09-12", sourceListingURL: nil,
                  priorRelationship: "none", production: "self", profile: "strong",
                  coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                  matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new)
    }

    // The overwhelmingly common case: Dan is on Scout and has ticked nothing. The selection bar draws
    // nothing, so no row set is needed to decide that.
    @Test func nothingTickedMeansNoRowsAreBuilt() {
        let source = RowSource([item("a"), item("b")])

        let result = QueueModel.probeSelection(dates: [], in: source.rows(), among: [],
                                               today: "2026-09-01", stage: .scout)

        #expect(result == nil)
        #expect(source.builds == 0)
    }

    // The bar belongs to Scout, so on any other stage the answer is known without looking at a row.
    // This is the case that made the sweep unconditional across the whole app rather than one stage.
    @Test func anotherStageMeansNoRowsAreBuilt() {
        let source = RowSource([item("a")])

        let result = QueueModel.probeSelection(dates: ["2026-09-12"], in: source.rows(), among: [],
                                               today: "2026-09-01", stage: .review)

        #expect(result == nil)
        #expect(source.builds == 0)
    }

    // And when there IS a selection to summarise, the rows are built, exactly once. Without this the
    // suite above would be satisfied by a function that never looks at its rows at all.
    @Test func arealSelectionBuildsItsRowsOnce() {
        let rows = [item("a"), item("b")]
        let source = RowSource(rows)

        let result = QueueModel.probeSelection(dates: Set(QueueModel.groupByDate(rows).map(\.id)),
                                               in: source.rows(), among: rows,
                                               today: "2026-09-01", stage: .scout)

        #expect(result != nil)
        #expect(source.builds == 1)
    }
}
