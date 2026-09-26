import Testing
import SwiftUI
import ViewInspector
@testable import Overture

// #4113: the genre line is a dropdown that saves on the choice, not a popover with a Save button.
//
// Measured on the issue: opening the old popover cost about a second of the main thread, and the queue's
// body never ran during it (`passes=0`, `rootDraws=0`). The time was SwiftUI building the popover's own
// window and re-laying out what was on screen, which a menu does not do: an ordinary menu is tracked by
// AppKit and writes nothing SwiftUI observes. Dan asked to see it before deciding ("Show me first",
// 2026-09-25, in the working session).
//
// What must survive the change, each asserted below: a choice is saved at once, the current genre chosen
// again writes nothing (an override flag set by a choice that changed nothing would stop every later scout
// refreshing a genre Dan never corrected, #1533), every genre is offered including the two that are not
// genres ("No genre read", "Not a live performance", #2813), and the control still announces itself.
@MainActor
@Suite("The genre line is a dropdown that saves on the choice (#4113)")
struct GenreDropdownTests {
    private func item(discipline: String) -> QueueItem {
        QueueItem(id: "k", groupName: "Brooklyn Ballet Collective", discipline: discipline,
                  venue: "Kaye Playhouse", performanceDate: "2026-11-14", sourceListingURL: nil,
                  priorRelationship: "none", production: "self", profile: "strong",
                  coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                  matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new)
    }

    final class Corrections { var chosen: [Discipline] = [] }

    private func row(_ discipline: String, _ corrections: Corrections) -> ProspectRowView {
        ProspectRowView(item: item(discipline: discipline), today: "2026-09-25", onKeep: {},
                        onDismiss: { _ in },
                        onCorrectClassification: { corrections.chosen.append($0) })
    }

    private func genrePicker(_ view: ProspectRowView) throws -> InspectableView<ViewType.Picker> {
        try view.inspect().find(ViewType.Picker.self) { picker in
            (try? picker.find(text: Discipline.notALivePerformance.label)) != nil
        }
    }

    @Test func choosingAnotherGenreSavesItAtOnce() throws {
        let corrections = Corrections()
        try genrePicker(row("music", corrections)).select(value: Discipline.dance)
        #expect(corrections.chosen == [.dance],
                "choosing a different genre must save it with no further step")
    }

    @Test func choosingTheCurrentGenreWritesNothing() throws {
        let corrections = Corrections()
        try genrePicker(row("music", corrections)).select(value: Discipline.music)
        #expect(corrections.chosen.isEmpty,
                "choosing the genre already on the card must not write, or later scouts stop refreshing it")
    }

    // A stored value no genre matches is SHOWN as "No genre read", and choosing that has to write it, so
    // the card and the store cannot disagree (`ClassificationResolution`'s own rule).
    @Test func aStoredValueNoGenreMatchesIsNormalisedWhenChosen() throws {
        let corrections = Corrections()
        try genrePicker(row("choral", corrections)).select(value: Discipline.other)
        #expect(corrections.chosen == [.other])
    }

    @Test func everyGenreIsOfferedIncludingTheTwoThatAreNotGenres() throws {
        let picker = try genrePicker(row("music", Corrections()))
        for discipline in Discipline.allCases {
            _ = try picker.find(text: discipline.label)
        }
        _ = try picker.find(text: "No genre read")
        _ = try picker.find(text: "Not a live performance")
    }

    @Test func theControlAnnouncesItselfForVoiceOver() throws {
        let menu = try row("dance", Corrections()).inspect().find(ViewType.Menu.self) { menu in
            (try? menu.find(ViewType.Picker.self)) != nil
        }
        #expect(try menu.accessibilityLabel().string() == GenreControlCopy.accessibilityLabel(for: "dance"))
        #expect(try menu.help().string() == GenreControlCopy.help)
    }
}
