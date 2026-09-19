import Testing
import SwiftUI
import ViewInspector
@testable import Overture

// #3282: the card admitting that the store holds this show more than once.
//
// Here rather than only in `StoredMoreThanOnceNoteTests`, which asserts the SENTENCE, because a
// sentence a view never renders says nothing (#1547 is this repository's own worked example of the
// branch that produces the copy and the branch that draws it being different questions). This drives
// the real `ProspectRowView`.
@MainActor
@Suite("A card shows that the same show is stored more than once (#3282)")
struct ProspectRowViewStoredMoreThanOnceTests {
    private func item(sameShowKeys: [String]) -> QueueItem {
        var item = QueueItem(id: "k", groupName: "We Are Happy To Serve You", discipline: "theater",
                             venue: "The Players Theatre", performanceDate: "2026-12-20",
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 7,
                             tier: "high", fitReason: "r", matchedClientName: nil,
                             possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        item.sameShowKeys = sameShowKeys
        return item
    }

    private func row(_ item: QueueItem) -> ProspectRowView {
        ProspectRowView(item: item, today: "2026-09-19", onKeep: {}, onDismiss: { _ in })
    }

    private func texts(_ view: ProspectRowView) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // The healthy day, which is almost every card: the line is absent entirely rather than rendering
    // an empty space where it would go.
    @Test func anOrdinaryCardSaysNothingAboutBeingStoredTwice() throws {
        #expect(!(try texts(row(item(sameShowKeys: [])))).contains { $0.contains("stored") })
    }

    @Test func aCardHoldingADuplicateSaysSo() throws {
        #expect(try texts(row(item(sameShowKeys: ["other"])))
            .contains { $0 == "This show is stored twice." })
    }

    // The archive's largest group today is twelve rows, so the many case is real and not theoretical.
    @Test func aCardInALargeGroupCountsEveryCopy() throws {
        let keys = (1...11).map { "other-\($0)" }
        #expect(try texts(row(item(sameShowKeys: keys)))
            .contains { $0 == "This show is stored 12 times." })
    }

    // Both themes, because a token that clears the contrast bar on one surface can be invisible on the
    // other, and the suite is the only place this gets looked at in dark (L606, L569).
    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func theNoteRendersInBothThemes(_ scheme: ColorScheme) throws {
        let view = row(item(sameShowKeys: ["other"])).environment(\.colorScheme, scheme)
        let found = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(found.contains { $0 == "This show is stored twice." })
    }
}
