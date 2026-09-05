import Testing
import Foundation

private func item(_ id: String, date: String?) -> QueueItem {
    QueueItem(
        id: id, groupName: id, discipline: "music", venue: "Weill Recital Hall",
        performanceDate: date, sourceListingURL: nil,
        priorRelationship: "none", production: "self", profile: "neutral",
        coverage: "unknown", fitScore: 5, tier: "mid", fitReason: "reason",
        matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new
    )
}

// #1922: putting a just-sent show back on screen without re-deriving the store.
//
// A fully sent show leaves the queue the instant the send lands, so the card that plays the leaving
// delight is a SNAPSHOT of a row the store no longer offers. That splice used to happen inside the
// whole-store derivation, which is why setting and clearing it re-derived every prospect twice per
// send. It happens here instead, over groups already built, so the send animates its own card.
//
// The case that makes this more than a move: sending the ONLY show on a night removes that night's group
// entirely, so the splice has to be able to put the group back, or the card Dan just sent vanishes
// instead of playing its send animation, which is the one thing he is looking at.
@Suite("A just-sent card is spliced back into the groups already built (#1922)")
struct DepartingRowsSpliceTests {
    @Test func nothingDepartingLeavesTheGroupsExactlyAsTheyWere() {
        let groups = QueueModel.groupByDate([item("a", date: "2026-07-01"), item("b", date: "2026-07-02")])
        #expect(QueueModel.groups(groups, withDeparting: [:]) == groups)
    }

    @Test func aDepartingShowRejoinsItsOwnNight() {
        let groups = QueueModel.groupByDate([item("a", date: "2026-07-01")])
        let sent = item("b", date: "2026-07-01")

        let spliced = QueueModel.groups(groups, withDeparting: ["b": sent])

        #expect(spliced.count == 1)
        #expect(spliced[0].items.map(\.id) == ["a", "b"])
    }

    // The load-bearing case. Nothing is left on that night, so there is no group to splice into.
    @Test func sendingTheOnlyShowOnANightKeepsThatNightOnScreen() {
        let groups = QueueModel.groupByDate([item("a", date: "2026-07-02")])
        let sent = item("b", date: "2026-07-01")

        let spliced = QueueModel.groups(groups, withDeparting: ["b": sent])

        #expect(spliced.map(\.id).contains("2026-07-01"))
        let night = spliced.first { $0.id == "2026-07-01" }
        #expect(night?.items.map(\.id) == ["b"])
        // And it is a real heading, not a bare date: the card lands under the same wording as any other.
        #expect(night?.monthDay == "Jul 1")
        #expect(night?.weekday.isEmpty == false)
    }

    // The store can still be offering the row for a frame while the send settles. Showing it twice would
    // draw the card next to its own farewell.
    @Test func aShowThatIsBothStillListedAndDepartingAppearsOnce() {
        let groups = QueueModel.groupByDate([item("a", date: "2026-07-01")])

        let spliced = QueueModel.groups(groups, withDeparting: ["a": item("a", date: "2026-07-01")])

        #expect(spliced.flatMap(\.items).map(\.id) == ["a"])
    }

    @Test func anUndatedDepartingShowLandsInTheUndatedGroup() {
        let groups = QueueModel.groupByDate([item("a", date: "2026-07-01")])

        let spliced = QueueModel.groups(groups, withDeparting: ["b": item("b", date: nil)])

        let undated = spliced.first { $0.id == "tbd" }
        #expect(undated?.items.map(\.id) == ["b"])
    }
}
