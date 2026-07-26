import Testing
import Foundation
@testable import Overture

private func item(key: String, date: String?) -> QueueItem {
    QueueItem(
        id: key, groupName: "Group \(key)", discipline: "music", venue: "Weill Recital Hall",
        performanceDate: date, sourceListingURL: nil, websiteURL: nil,
        priorRelationship: "none", production: "unknown", profile: "neutral",
        coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "reason",
        matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new
    )
}

// #1573: picking a global search result did nothing when the show was already in the focused stage.
// The jump asked ScrollViewProxy for the ROW's id, but the queue's scroll position is owned by
// scrollPosition($topGroup) over a scrollTargetLayout whose targets are the DATE GROUPS, so the two
// mechanisms fought and the jump was dropped. The jump now names a group the layout actually draws,
// which is what these pin.
//
// The ids matter twice over: the show groups and the hire-inquiry groups sit in the SAME layout and
// were both keyed on the bare date, so on any day holding both, one id named two different targets
// and a jump could land on the inquiry block instead of the show Dan picked.
@Suite("A queue jump names a scroll target the layout draws (#1573)")
struct QueueScrollTargetTests {
    private let items = [
        item(key: "a", date: "2026-08-14"),
        item(key: "b", date: "2026-09-02"),
        item(key: "c", date: "2026-09-02"),
        item(key: "undated", date: nil)
    ]

    // The point of the fix: a row deep in the list resolves to ITS OWN group, not the first one.
    @Test func aRowResolvesToTheGroupHoldingIt() {
        #expect(QueueModel.scrollGroupID(containing: "c", among: items)
                == QueueModel.showGroupScrollID("2026-09-02"))
        #expect(QueueModel.scrollGroupID(containing: "a", among: items)
                == QueueModel.showGroupScrollID("2026-08-14"))
    }

    // The undated bucket is a real group with a real header, so a jump to an undated show must land
    // on it rather than giving up.
    @Test func anUndatedRowResolvesToTheUndatedGroup() {
        let id = QueueModel.scrollGroupID(containing: "undated", among: items)
        #expect(id == QueueModel.showGroupScrollID("tbd"))
        #expect(id != nil)
    }

    // The failure path: a key that is not in the rendered rows at all (dismissed between the search
    // and the tap, or in another stage) yields nothing to scroll to, rather than a plausible wrong id.
    @Test func anAbsentRowResolvesToNothing() {
        #expect(QueueModel.scrollGroupID(containing: "not-here", among: items) == nil)
        #expect(QueueModel.scrollGroupID(containing: "a", among: []) == nil)
    }

    // Every id the jump can produce is one groupByDate actually publishes, so the two can never drift
    // into naming a target the layout does not draw.
    @Test func everyResolvedIDIsAGroupTheLayoutDraws() {
        let drawn = Set(QueueModel.groupByDate(items).map { QueueModel.showGroupScrollID($0.id) })
        for row in items {
            guard let id = QueueModel.scrollGroupID(containing: row.id, among: items) else {
                Issue.record("every rendered row should resolve to a group; \(row.id) did not")
                continue
            }
            #expect(drawn.contains(id))
        }
    }

    // The collision this fix closes: a show group and an inquiry group on the SAME date are two
    // different targets in one layout, so they must never answer to the same id.
    @Test func showAndInquiryGroupsOnOneDateAreDistinctTargets() {
        #expect(QueueModel.showGroupScrollID("2026-08-14")
                != QueueModel.inquiryGroupScrollID("2026-08-14"))
        // And the bare date is not itself a target id any more, in either namespace.
        #expect(QueueModel.showGroupScrollID("2026-08-14") != "2026-08-14")
        #expect(QueueModel.inquiryGroupScrollID("2026-08-14") != "2026-08-14")
    }
}
