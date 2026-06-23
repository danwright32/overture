import Testing
@testable import Overture

// #18: imported booking history stores presenter + program title, often multi-line, in
// either order. Matching must isolate the presenter/org wherever it sits, or a real warm
// client gets scored cold (losing the top fit signal behind the ~79% warm conversion).
@Suite("Group-name normalization across messy history")
struct GroupNameDriftTests {
    @Test func extractsThePresenterFromAnyLineNotJustTheFirst() {
        // Presenter first (already worked).
        #expect(GroupNameMatch.normalize("Presented by Jazzical Arts\nKomitas: Passion of Fire") == "jazzical arts")
        // Presenter on a later line (the gap): the org must still be isolated.
        #expect(GroupNameMatch.normalize("Komitas: Passion of Fire\nPresented by Jazzical Arts") == "jazzical arts")
    }

    @Test func plainMultilineStillUsesTheFirstLine() {
        #expect(GroupNameMatch.normalize("Indianapolis Children's Choir\nSpring Concert") == "indianapolis children s choir")
    }

    @Test func confidentlyMatchesADiscoveredOrgAgainstAMessyHistoryEntry() {
        #expect(GroupNameMatch.isConfident("Jazzical Arts", "Komitas: Passion of Fire\nPresented by Jazzical Arts"))
    }
}
