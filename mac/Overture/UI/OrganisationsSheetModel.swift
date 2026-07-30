import Foundation

// #1731: everything the Presenters sheet derives, in one value built ONCE, out of the view.
//
// This exists because "built once" was claimed and was not true. The listing was a computed property on
// the view, so SwiftUI rebuilt it on every read: once per section and again on every keystroke in the
// search field. Deciding it walks every presenter in the store against every venue spelling in it, which
// is the exact pattern QueueView records freezing the machine (#1121).
//
// A claim about how many times something runs is only testable if something can count the runs, which is
// what the injectable builder is for. It is not a convenience: without it the "once" is an assertion in a
// comment, and this file is the second attempt at making it true.
struct OrganisationsSheetModel {
    // Every organisation, in the order the sheet reads them.
    let all: [OrganisationListing.Entry]
    // The three slices the sheet shows, sliced once here rather than filtered again per redraw.
    let shortlist: [OrganisationListing.Entry]
    let buildings: [OrganisationListing.Entry]
    let sharing: [OrganisationListing.Entry]

    init(shows: [OrganisationListing.Show],
         overrides: ProducerOverrides,
         build: ([OrganisationListing.Show], ProducerOverrides) -> [OrganisationListing.Entry]
            = { OrganisationListing.build(shows: $0, overrides: $1) }) {
        let entries = build(shows, overrides)
        all = entries
        buildings = entries.filter { $0.verdict == .theBuilding }
        sharing = entries.filter { $0.verdict == .sharesOneAnswer }
        // #1729: refused, uncorrected, and covering enough rows that a correction is worth something.
        let minimum = OrganisationListing.shortlistMinimumRows
        shortlist = entries.filter {
            $0.verdict == .paidForSeparately && $0.standing == .none && $0.rowCount >= minimum
        }
    }

    // Filters what already exists. Never derives, which is the half that used to run on every character.
    func matches(_ search: String) -> [OrganisationListing.Entry] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return all.filter { $0.name.lowercased().contains(needle) }
    }
}
