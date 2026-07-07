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
