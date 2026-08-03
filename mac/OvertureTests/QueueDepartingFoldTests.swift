import Testing

// #361: the just-sent rows playing their leaving delight are folded back into the displayed rows so
// each glides out in place. That fold is pure list logic, pulled out of the SwiftUI view so it can be
// tested: a departing row shows even though the send already removed it from `visible`, and it is
// never shown twice if `visible` briefly still holds it before the data refilters.
@Suite("Queue folds departing rows back in (#361)")
struct QueueDepartingFoldTests {
    private func item(_ key: String) -> QueueItem {
        QueueItem(
            id: key, groupName: "G", discipline: "choral", venue: "V",
            performanceDate: "2026-07-20", sourceListingURL: nil, websiteURL: nil,
            priorRelationship: "none", production: "self", profile: "neutral",
            coverage: "likely_uncovered", fitScore: 5, tier: "medium", fitReason: "r",
            matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .approved)
    }

    @Test func aDepartingRowIsShownEvenThoughItLeftVisible() {
        let out = QueueModel.withDeparting([item("a")], departing: ["b": item("b")])
        #expect(Set(out.map(\.id)) == ["a", "b"])
    }

    @Test func aDepartingRowStillInVisibleIsNotDuplicated() {
        let a = item("a")
        let out = QueueModel.withDeparting([a], departing: ["a": a])
        #expect(out.map(\.id) == ["a"])   // shown once, from the departing snapshot
    }

    @Test func noDepartingRowsLeavesVisibleUntouched() {
        let out = QueueModel.withDeparting([item("a"), item("b")], departing: [:])
        #expect(out.map(\.id) == ["a", "b"])
    }
}
