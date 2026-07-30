import Testing
import Foundation
@testable import Overture

// #1731: the Presenters sheet's whole derivation, out of the view so it can be counted.
//
// The defect this exists to prevent shipped once and was claimed fixed in a PR while it was not: the
// listing was a COMPUTED property, so SwiftUI rebuilt it on every read, which is once per section and
// again on every keystroke in the search field. Deciding it walks every presenter in the store against
// every venue spelling in it. QueueView records the same pattern freezing the machine (#1121).
//
// "Built once" is a claim about how many times a function runs, so it is only testable if something can
// count the runs. That is what the injectable builder below is for; it is not a convenience.
@Suite("The Presenters sheet builds its listing once (#1731)")
struct OrganisationsSheetModelTests {

    private func shows() -> [OrganisationListing.Show] {
        [
            OrganisationListing.Show(presenter: "The Green Room 42", venue: "The Green Room 42", title: "A Cabaret"),
            OrganisationListing.Show(presenter: "FRIGID New York", venue: "Under St Marks", title: "One"),
            OrganisationListing.Show(presenter: "FRIGID New York", venue: "Under St Marks", title: "Two"),
            OrganisationListing.Show(presenter: "FRIGID New York", venue: "Under St Marks", title: "Three"),
            OrganisationListing.Show(presenter: "Young Concert Artists", venue: "Merkin Hall", title: "A Debut"),
            OrganisationListing.Show(presenter: "Young Concert Artists", venue: "The Cutting Room", title: "B Debut"),
        ]
    }

    // The whole point. Building the model runs the expensive derivation exactly once, however many
    // sections read it afterwards.
    @Test func theExpensiveDerivationRunsOnceHoweverManySectionsReadIt() {
        var builds = 0
        let model = OrganisationsSheetModel(shows: shows(), overrides: .none) { shows, overrides in
            builds += 1
            return OrganisationListing.build(shows: shows, overrides: overrides)
        }
        _ = model.shortlist
        _ = model.shortlist
        #expect(builds == 1)
    }

    // The shortlist still holds what it held: the organisation whose shows sit oddly, and neither the
    // building nor the travelling producer beside it.
    @Test func onlyTheOddLookingOrganisationIsShortlisted() {
        let model = OrganisationsSheetModel(shows: shows(), overrides: .none)
        #expect(model.shortlist.map(\.name) == ["FRIGID New York"])
    }

}
