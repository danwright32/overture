import Foundation

// #953: what the Prep-selection sheet says to Dan, kept out of the view so the wording is testable
// (#885: a sentence computed in a SwiftUI body is a sentence no test can reach). The sheet lets Dan
// choose which kept shows a single Prep run covers, defaulted by how far out each show is
// (PrepQueueBuilder.defaultsIncludedInPrepRun). The selection is per-run and transient; nothing here
// persists a choice.
enum PrepSelectionCopy {
    // The heading: the one question the sheet asks.
    static let title = "Which kept shows to prep?"

    // Why some rows open unchecked, and what Dan can do about it. Without this the pre-unchecked far-out
    // rows read as a bug rather than a deliberate default.
    static let subtitle = "Shows too far out to pitch yet start unchecked. Include any you want prepped now."

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
