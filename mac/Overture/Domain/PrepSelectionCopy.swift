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

    // MARK: - #3325, the nights of a run

    // #3311: said ONCE, at the top of the sheet, when the calendar could not be read. Every night below is
    // then unmarked, and without this an unmarked night reads as a clear one (L98).
    static let calendarUnread =
        "Your Downbeat calendar could not be read, so no night here is checked against it."

    // The disclosure's label: how many of the run's nights this press pitches. The count is the ticks, so
    // the label and the boxes cannot disagree.
    static func nightsSummary(ticked: Int, of total: Int) -> String {
        if ticked == total { return "All \(total) nights" }
        if ticked == 0 { return "No nights" }
        return "\(ticked) of \(Plural.count(total, "night"))"
    }

    // Under a run with every night unticked. Unticking is not a dismissal (Dan, 2026-09-17), so the show
    // is simply left out of this run, and dismissing it stays on the card, which asks why (2026-08-30).
    static let noNightLeft =
        "No night is ticked, so this show stays out of this run. To dismiss it, use Dismiss on its card."

    // A run stored with a span and no nights. Measured 2026-09-17, none of these has ever gained nights
    // (#3963), so this is the row's permanent state, and the sentence says what happens rather than
    // rendering an empty list (L10).
    static let nightsNotRecorded =
        "Overture never recorded which nights this run plays, so it is prepped for the whole run."

    // One night's own label: "Fri Nov 6".
    static func nightLabel(_ day: String) -> String {
        EasternDate.weekdayDayLabel(day) ?? day
    }

    // The clash under a night, in the calendar's own sentence. A night Dan already answered keeps the
    // sentence and says how he answered it, so the fact he is overriding is never hidden from him.
    static func clashNote(_ clash: PrepNightPlan.Clash) -> String? {
        switch clash {
        case .clear: return nil
        case .blocked(let day): return day.reason(scope: .thisNight)
        case .waived(let day): return "\(day.reason(scope: .thisNight)) You cleared this on the card."
        case .accepted(let day): return "\(day.reason(scope: .thisNight)) You pitched it anyway last time."
        }
    }

    // The nights grouped by the week they fall in, Monday first, each labelled "Week of Nov 2". A 28 night
    // run is four or five short groups rather than one column of 28 dates (plan 3.3).
    struct Week: Hashable {
        let label: String
        let nights: [String]
    }

    static func weeks(_ nights: [String]) -> [Week] {
        var order: [String] = []
        var byWeek: [String: [String]] = [:]
        for night in nights.sorted() {
            let start = EasternDate.weekStart(night) ?? night
            if byWeek[start] == nil { order.append(start) }
            byWeek[start, default: []].append(night)
        }
        return order.map { start in
            Week(label: "Week of \(EasternDate.dayLabel(start) ?? start)", nights: byWeek[start] ?? [])
        }
    }

    // After a launch that left a run out because its nights changed while the sheet was open. Named, so
    // Dan knows which show to look at; the next open of the sheet shows its nights as they are now.
    static func leftOut(_ names: [String]) -> String {
        "Left out of this run because its nights changed while the sheet was open: "
            + names.joined(separator: ", ") + "."
    }
}
