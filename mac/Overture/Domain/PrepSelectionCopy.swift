import Foundation

// #953: what the Prep-selection sheet says to Dan, kept out of the view so the wording is testable
// (#885: a sentence computed in a SwiftUI body is a sentence no test can reach). The sheet lets Dan
// choose which kept shows a single Prep run covers. #2365: every eligible show starts checked, because
// Scout is the only surface that applies a lead time window, so anything reaching this sheet is a show
// Dan deliberately kept. The selection is per-run and transient; nothing here persists a choice.
enum PrepSelectionCopy {
    // The heading: the one question the sheet asks.
    static let title = "Which kept shows to prep?"

    // #2365: every row opens checked, so this says what the sheet is FOR rather than explaining an
    // exception that no longer exists. Without a second line the sheet is a bare list of ticked rows and
    // a Prep button, and nothing tells Dan he may narrow the run.
    //
    // "All of these" rather than "every kept show", read cold in both branches: the title already says
    // "kept shows", so naming them again is the #843 echo, and "every kept show" reads oddly over a list
    // holding one. "These" points at the rows under it and is true at any count.
    static let subtitle = "All of these are included. Uncheck any you would rather not prep in this run."

    // The Cancel button keeps its own bare, static "Cancel" literal at the call site, matching every
    // other cancel/dismiss control in the app; a one-word label carries no rule worth centralizing here.

    // The run button: how many shows the current selection will prep, pluralized ("Prep 1 show",
    // "Prep 3 shows"). The count is the number of checked rows, so this sentence and the checkboxes can
    // never disagree.
    static func runButton(_ count: Int) -> String { "Prep \(Plural.count(count, "show"))" }

    // A row's dim second line: where and when the show is, as Dan reads it. Venue then date, joined only
    // when both are present. The date is the whole basis of the default, so it earns its place here. When
    // neither is known the line is empty and the sheet hides it, rather than adding a third copy of
    // "Date to be confirmed" (already duplicated in QueueView+Model, #843) that would only drift.
    static func rowDetail(venue: String?, performanceDate: String?) -> String {
        let date = performanceDate.flatMap(EasternDate.dayLabel)
        return [venue, date].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
