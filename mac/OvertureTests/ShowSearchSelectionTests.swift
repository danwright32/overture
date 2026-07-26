import Testing
import Foundation
@testable import Overture

// #1574. The arithmetic behind driving the search dropdown from the keyboard, kept out of the view
// so it can be tested at all (a SwiftUI body's @State is unreachable from a test). Dan's call on the
// starting state: nothing is highlighted until he presses an arrow, and Return is inert until then,
// so typing a name and hitting Return by reflex can never open a show he did not look at.
@Suite("Keyboard selection in the show search results")
struct ShowSearchSelectionTests {
    @Test func startsWithNothingHighlighted() {
        let selection = ShowSearchSelection()
        #expect(selection.index == nil)
        #expect(selection.commitIndex(resultCount: 3) == nil,
                "Return must do nothing until Dan has actually moved onto a result.")
    }

    @Test func firstDownArrowHighlightsTheTopResult() {
        var selection = ShowSearchSelection()
        selection.moveDown(resultCount: 3)
        #expect(selection.index == 0)
        #expect(selection.commitIndex(resultCount: 3) == 0)
    }

    @Test func firstUpArrowHighlightsTheLastResult() {
        var selection = ShowSearchSelection()
        selection.moveUp(resultCount: 3)
        #expect(selection.index == 2)
    }

    @Test func downArrowStopsOnTheLastResult() {
        var selection = ShowSearchSelection()
        for _ in 0..<5 { selection.moveDown(resultCount: 3) }
        #expect(selection.index == 2,
                "holding the arrow down past the end must rest on the last result, not wrap round to the top.")
    }

    @Test func upArrowStopsOnTheFirstResult() {
        var selection = ShowSearchSelection()
        selection.moveDown(resultCount: 3)
        selection.moveDown(resultCount: 3)
        for _ in 0..<5 { selection.moveUp(resultCount: 3) }
        #expect(selection.index == 0)
    }

    @Test func aNewQueryClearsTheHighlight() {
        var selection = ShowSearchSelection()
        selection.moveDown(resultCount: 3)
        selection.clear()
        #expect(selection.index == nil)
        #expect(selection.commitIndex(resultCount: 3) == nil,
                "after editing the query the old highlight is meaningless: Return must be inert again.")
    }

    // Failure paths: the result list can be empty (a query that matches nothing still shows the
    // popover, by #885), and it can shrink under a highlight that was valid a moment ago.
    @Test func arrowsDoNothingWhenThereAreNoResults() {
        var selection = ShowSearchSelection()
        selection.moveDown(resultCount: 0)
        #expect(selection.index == nil)
        selection.moveUp(resultCount: 0)
        #expect(selection.index == nil)
        #expect(selection.commitIndex(resultCount: 0) == nil)
    }

    @Test func aHighlightPastAShrunkenListCommitsNothing() {
        var selection = ShowSearchSelection()
        for _ in 0..<4 { selection.moveDown(resultCount: 8) }
        #expect(selection.index == 3)
        #expect(selection.commitIndex(resultCount: 2) == nil,
                "a stale index must never be handed to the result list as a subscript.")
    }
}
