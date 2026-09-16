import Testing
import Foundation

// #3654: the list holds ROWS, so the groups going in are rows and the departing snapshot stays a CARD.
// That asymmetry is what the splice is about now: a show that has just left has no card the store could
// build, only the one taken when Dan pressed.
private func row(_ id: String, date: String?) -> QueueScopeRow {
    QueueScopeRow(id: id, groupName: id, discipline: "music", venue: "Weill Recital Hall",
                  performanceDate: date, fitScore: 5)
}

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
        let groups = QueueModel.groupByDate([row("a", date: "2026-07-01"), row("b", date: "2026-07-02")])
        #expect(QueueModel.groups(groups, withDeparting: [:]) == groups)
    }

    @Test func aDepartingShowRejoinsItsOwnNight() {
        let groups = QueueModel.groupByDate([row("a", date: "2026-07-01")])
        let sent = item("b", date: "2026-07-01")

        let spliced = QueueModel.groups(groups, withDeparting: ["b": sent])

        #expect(spliced.count == 1)
        #expect(spliced[0].items.map(\.id) == ["a", "b"])
    }

    // The load-bearing case. Nothing is left on that night, so there is no group to splice into.
    @Test func sendingTheOnlyShowOnANightKeepsThatNightOnScreen() {
        let groups = QueueModel.groupByDate([row("a", date: "2026-07-02")])
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
        let groups = QueueModel.groupByDate([row("a", date: "2026-07-01")])

        let spliced = QueueModel.groups(groups, withDeparting: ["a": item("a", date: "2026-07-01")])

        #expect(spliced.flatMap(\.items).map(\.id) == ["a"])
    }

    @Test func anUndatedDepartingShowLandsInTheUndatedGroup() {
        let groups = QueueModel.groupByDate([row("a", date: "2026-07-01")])

        let spliced = QueueModel.groups(groups, withDeparting: ["b": item("b", date: nil)])

        let undated = spliced.first { $0.id == "tbd" }
        #expect(undated?.items.map(\.id) == ["b"])
    }

    // #3634. Dan, 2026-09-07: "I dismissed a whole night and it moved me to the bottom of the scout
    // queue. I was in september now I'm looking at may."
    //
    // A night keeps its date position while every one of its rows is departing. The queue pins its
    // scroll to the date group at the top of the screen, so the group Dan is reading IS the night he is
    // dismissing: rebuilt at the end of the list, the scroll follows it there.
    @Test func aNightWhoseEveryRowIsDepartingKeepsItsDatePosition() {
        let groups = QueueModel.groupByDate([row("a", date: "2026-07-01"), row("c", date: "2026-07-03")])
        let dismissed = item("b", date: "2026-07-02")

        let spliced = QueueModel.groups(groups, withDeparting: ["b": dismissed])

        #expect(spliced.map(\.id) == ["2026-07-01", "2026-07-02", "2026-07-03"])
    }

    // The undated bucket is not a date and cannot be placed by one. It stays last however the dated
    // nights fall, which is what `QueueModelTests` already pins for `groupByDate` itself.
    @Test func aDepartingOnlyUndatedNightStaysLastRatherThanTakingADatePosition() {
        let groups = QueueModel.groupByDate([row("a", date: "2026-07-01"), row("c", date: "2026-07-03")])

        let spliced = QueueModel.groups(groups, withDeparting: ["b": item("b", date: nil),
                                                                "d": item("d", date: "2026-07-02")])

        #expect(spliced.map(\.id) == ["2026-07-01", "2026-07-02", "2026-07-03", "tbd"])
    }

    // The incoming order is the derivation's, not a date sort, and the splice may not overrule it. Other
    // callers group on their own key and order their own way, so a global sort here would silently
    // reorder every surface that does not happen to already be in date order.
    @Test func theIncomingOrderOfSurvivingNightsIsPreservedRatherThanSorted() {
        let groups = QueueModel.groupByDate([row("a", date: "2026-07-05"), row("c", date: "2026-07-01")])

        let spliced = QueueModel.groups(groups, withDeparting: ["b": item("b", date: "2026-07-05")])

        #expect(spliced.map(\.id) == ["2026-07-05", "2026-07-01"])
    }
}
