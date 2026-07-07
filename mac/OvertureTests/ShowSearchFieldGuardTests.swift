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
        #expect(src.contains("ShowSearch.matches("))
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

    @Test func popoverPresentationIsDrivenByFocusAndAQuery() {
        #expect(src.contains("showDropdown = focused && !trimmedQuery.isEmpty"))
        #expect(src.contains("showDropdown = isFocused && !trimmedQuery.isEmpty"))
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

    @Test func popoverContentShowsANoMatchesMessageWhenEmpty() {
        #expect(src.contains("matches.isEmpty"))
        #expect(src.contains("No matches"))
    }
}
