import Testing
import Foundation

// View only change with no independently testable behavior beyond ShowSearch itself (covered by
// ShowSearchTests): confirms the field actually wires into the shared matcher instead of rolling
// its own comparison.
@Suite("ShowSearchField uses the shared matcher")
struct ShowSearchFieldGuardTests {
    @Test func wiresToShowSearchMatches() {
        let src = SourceGuardHelper.source("Overture/UI/ShowSearchField.swift")
        #expect(!src.isEmpty)
        // #1926: the matcher is reached through ShowSearch.results/matchCount, which is where the
        // filtering, the ordering and the cap now live (and where a test can read them).
        #expect(src.contains("ShowSearch.results("))
        #expect(src.contains("ShowSearch.matchCount("))
    }
}

// Regression guard: confirmed against the running app that a real macOS NSToolbar clips or refuses
// to host any content taller than its own fixed strip, so an inline VStack dropdown never appeared
// at all when this field lived in the main window's toolbar (only the search bar itself rendered
// there). The results list must render as a popover, a separate floating window layer, not inline
// content, or the search feature is unusable from the toolbar.
@Suite("ShowSearchField results render as a popover, not inline content")
struct ShowSearchFieldPopoverGuardTests {
    private var src: String { SourceGuardHelper.source("Overture/UI/ShowSearchField.swift") }

    @Test func resultsUsePopoverNotAnInlineDropdown() {
        #expect(!src.isEmpty)
        #expect(src.contains(".popover(isPresented:"),
                "the results list must render via .popover, not an inline VStack row, or it will not appear at all when this field is hosted in a native toolbar.")
    }

    // #1926: "there is something typed" is ShowSearch.isSearching now, one definition shared with the two
    // search helpers, so the dropdown cannot open on a query the matcher would treat as blank.
    @Test func popoverPresentationIsDrivenByFocusAndAQuery() {
        #expect(src.contains("showDropdown = focused && isSearching"))
        #expect(src.contains("showDropdown = isFocused && isSearching"))
        #expect(src.contains("ShowSearch.isSearching(query)"))
    }
}

// Regression guard: Dan typed a real query into the live search bar and, because the search
// genuinely found zero matches, saw no feedback at all ("the search doesn't seem to be doing
// anything"). A true zero-result search must look different from the field simply not responding,
// so the popover has to keep showing (with an explicit "no matches" message) even when the match
// list itself is empty, as long as there's something typed.
@Suite("ShowSearchField shows explicit feedback when a search finds nothing")
struct ShowSearchFieldNoResultsGuardTests {
    private var src: String { SourceGuardHelper.source("Overture/UI/ShowSearchField.swift") }

    @Test func popoverOpensEvenWithZeroMatchesSoANoResultsMessageCanShow() {
        #expect(!src.isEmpty)
        #expect(!src.contains("showDropdown = focused && !matches.isEmpty"),
                "gating purely on matches.isEmpty means a real zero-result search looks identical to a broken one; it must open on a non-empty query instead.")
        #expect(!src.contains("showDropdown = isFocused && !matches.isEmpty"))
    }

    // #885: the SENTENCE moved out of the view, where a test can read it rather than merely confirm its
    // presence here. Same protection, checked on the wire: the empty branch still renders that note, so a
    // zero-result search can never silently show nothing at all. #1580 widened the helper to
    // ShowSearch.emptyState, which decides between the plain note and the one carrying the Archive jump.
    @Test func popoverContentShowsANoMatchesMessageWhenEmpty() {
        // #1926: the popover reads its results once into a local, so the empty branch is keyed on that.
        #expect(src.contains("if results.isEmpty"))
        #expect(src.contains("ShowSearch.emptyState("))
    }
}

// #1574. The behavior is tested in ShowSearchSelectionTests; what a test cannot reach is whether the
// view's key handling actually goes through that type instead of doing its own index arithmetic in a
// closure, which is how this logic became untestable in the first place.
@Suite("ShowSearchField drives its results from the shared selection type")
struct ShowSearchFieldKeyboardGuardTests {
    private var src: String { SourceGuardHelper.source("Overture/UI/ShowSearchField.swift") }

    @Test func arrowsAndReturnRouteThroughShowSearchSelection() {
        #expect(!src.isEmpty)
        #expect(src.contains("selection.moveDown(resultCount:"))
        #expect(src.contains("selection.moveUp(resultCount:"))
        #expect(src.contains("selection.commitIndex(resultCount:"),
                "Return must ask the selection what to open, so the empty-highlight and stale-index cases stay in one tested place.")
    }

    @Test func arrowsAreIgnoredWhenThereIsNoResultListToMoveThrough() {
        #expect(src.contains("guard showDropdown, !results.isEmpty else { return .ignored }"),
                "swallowing the arrow keys with no results on screen would break the text field's own caret movement.")
    }
}
