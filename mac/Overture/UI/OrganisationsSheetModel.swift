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
    // The one slice the sheet shows, sliced once here rather than filtered again per redraw.
    //
    // #1731: it used to expose the buildings, the answer-sharing organisations and every name for search
    // as well. Dan read that sheet and said "I'm not sure what to do with it", and he was right: four
    // read-only sections and a search box are a wall of facts with no decision in them. Those questions
    // are now answered on the card that prompts them, so the slices they needed are gone rather than left
    // unwired (L29).
    let shortlist: [OrganisationListing.Entry]

    init(shows: [OrganisationListing.Show],
         overrides: ProducerOverrides,
         build: ([OrganisationListing.Show], ProducerOverrides) -> [OrganisationListing.Entry]
            = { OrganisationListing.build(shows: $0, overrides: $1) }) {
        let entries = build(shows, overrides)
        // #1729: refused, uncorrected, and covering enough rows that a correction is worth something.
        let minimum = OrganisationListing.shortlistMinimumRows
        shortlist = entries.filter {
            $0.verdict == .paidForSeparately && $0.standing == .none && $0.rowCount >= minimum
        }
    }

}
