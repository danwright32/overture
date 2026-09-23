import Testing
import SwiftUI
import ViewInspector
@testable import Overture

// #4146: the card that was already there, saying a later listing looks like the same show.
//
// Here as well as in `BothCardsSayItTests`, which asserts the sentence and the reverse walk that
// resolves it, because a sentence a view never renders says nothing (#1995). This drives the real
// `ProspectRowView`, and it is the only place the two ends of one pairing are drawn together.
@MainActor
@Suite("The older card says a later listing looks like it (#4146)")
struct ProspectRowViewLaterLookalikeTests {
    private func item(later: [String] = [], arrivedLookingLike: String? = nil) -> QueueItem {
        var item = QueueItem(id: "k", groupName: "Orli Shaham, piano", discipline: "music",
                             venue: "Merkin Hall", performanceDate: "2026-11-02",
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 7,
                             tier: "high", fitReason: "r", matchedClientName: nil,
                             possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        item.laterLookalikeTitles = later
        item.arrivedLookingLikeTitle = arrivedLookingLike
        return item
    }

    private func texts(_ item: QueueItem) throws -> [String] {
        try ProspectRowView(item: item, today: "2026-09-22", onKeep: {}, onDismiss: { _ in })
            .inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // The healthy day, which is all but two cards in the store.
    @Test func anordinaryCardSaysNothingAboutALaterListing() throws {
        #expect(!(try texts(item())).contains { $0.contains("later listing") })
    }

    @Test func theolderCardNamesTheLaterListing() throws {
        #expect(try texts(item(later: ["Orli Shaham: In Clara's Hands"]))
            .contains { $0 == "A later listing looks like the same show: \"Orli Shaham: In Clara's Hands\"." })
    }

    // SEVERAL POINTERS are counted with the newest named, never listed, which is the rule #3282
    // recorded: naming each rebuilds the wall of identical text this milestone keeps removing (L579).
    @Test func severalLaterListingsAreCountedWithTheNewestNamed() throws {
        let found = try texts(item(later: ["Orli Shaham: In Clara's Hands", "Orli Shaham plays Schumann"]))
        #expect(found.contains { $0 == "2 later listings look like the same show, the newest \"Orli Shaham: In Clara's Hands\"." })
        #expect(!found.contains { $0.contains("Schumann") },
                "the second pointer was named as well as counted, which is the wall of text again")
    }

    // THE MIDDLE OF A CHAIN, which the row view's comment used to say could not happen. A third listing
    // tags whichever stored row `LookalikeOnArrival` reaches first, and that can be a row which itself
    // arrived looking like an earlier one. Both sentences are then about DIFFERENT rows and both are
    // true, so the card draws both, in the order a person reads them.
    @Test func acardInTheMiddleOfAChainDrawsBothHalves() throws {
        let found = try texts(item(later: ["Orli Shaham: In Clara's Hands"],
                                   arrivedLookingLike: "Orli Shaham, pianist"))
        #expect(found.contains { $0 == "Looks like the same show as Orli Shaham, pianist, already stored for this night." })
        #expect(found.contains { $0 == "A later listing looks like the same show: \"Orli Shaham: In Clara's Hands\"." })
    }

    // Both themes, for the same reason every other card note is checked in both (L606, L569).
    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func thenoteRendersInBothThemes(_ scheme: ColorScheme) throws {
        let view = ProspectRowView(item: item(later: ["Orli Shaham: In Clara's Hands"]),
                                   today: "2026-09-22", onKeep: {}, onDismiss: { _ in })
            .environment(\.colorScheme, scheme)
        let found = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(found.contains { $0.contains("A later listing looks like the same show") })
    }
}
