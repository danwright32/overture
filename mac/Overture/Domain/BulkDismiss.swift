import Foundation

// #1500: dismissing every show on one date in a single action, for one reason Dan picks.
//
// Dan's words (2026-07-25, from the Jul 24 2026 queue): "I need a way to auto dismiss everything on one
// date. Like if I want to mark everything on a single date as 'Too soon', or in this case as 'Date
// conflict'." A busy Friday can carry five or more cards, and every dismissal was one card at a time.
//
// The rule and the words both live here rather than in the date header, for the #863 reason: what Dan
// reads immediately before several shows leave the queue at once has to be testable, and a sentence
// assembled in a view is invisible to the copy inventory (#915), so his PR would not show the words.
//
// It decides nothing about WHICH rows: the caller hands over the rows that group is currently rendering,
// so a filter or a search that narrows the night narrows the action with it.
enum BulkDismiss {
    // The little a decision needs from a queue row, so the rule stays in the domain and does not depend on
    // the view's QueueItem. Mirrors EngagementLink.Row, which solves the same shape.
    struct Show: Equatable, Sendable {
        let key: String
        let groupName: String
        let performanceDate: String?
        let runEndDate: String?
    }

    struct Plan: Equatable, Sendable {
        let keys: [String]
        // The shows whose run plays on AFTER this night, by name. A multi-night run appears under each of
        // its dates, so dismissing one of them dismisses the whole prospect: naming them is what stops
        // losing Jul 31 from being a surprise sprung by an action that said "Jul 24".
        let runsPastTheNight: [String]
        // #1500 follow-up (Dan, 2026-07-26, on a Jul 26 group of 12 where 4 were runs): the shows that
        // exist ONLY on this night, so he can clear the night without touching anything that plays on.
        let keysOnlyThisNight: [String]

        var count: Int { keys.count }
        var isEmpty: Bool { keys.isEmpty }
        // Worth offering only when both sides exist. With no runs the two buttons would do the same thing;
        // with nothing BUT runs the narrower one would dismiss nothing at all.
        var offersChoice: Bool { !runsPastTheNight.isEmpty && !keysOnlyThisNight.isEmpty }
    }

    static func plan(for shows: [Show], on date: String) -> Plan {
        Plan(keys: shows.map(\.key),
             runsPastTheNight: shows.filter { playsPast(date, $0) }.map(\.groupName),
             keysOnlyThisNight: shows.filter { !playsPast(date, $0) }.map(\.key))
    }

    // Judged with EasternDate.runLastNight, the same definition of "the last night of this run" the
    // conflict calculator, the feed reconcile and the day off offer all use.
    private static func playsPast(_ date: String, _ show: Show) -> Bool {
        guard let start = show.performanceDate,
              let lastNight = EasternDate.runLastNight(runEndDate: show.runEndDate, performanceDate: start)
        else { return false }
        return lastNight > date
    }

    // MARK: - What Dan reads before it happens

    // The action is reached by right-clicking a date, so the menu itself has to say what it does and how
    // much of the night it covers: under a right-click, a bare list of dismiss reasons says neither.
    static func menuTitle(count: Int, dateLabel: String) -> String {
        count == 1 ? "Dismiss the show on \(dateLabel)"
                   : "Dismiss all \(Plural.count(count, "show")) on \(dateLabel)"
    }

    static func confirmTitle(count: Int, dateLabel: String) -> String {
        "\(menuTitle(count: count, dateLabel: dateLabel))?"
    }

    // Names the reason every row is about to carry, then the runs that lose their later nights. Bulk
    // dismissal is exactly where a wrong reason gets written to many shows at once, so the reason is
    // stated, never implied by the menu item Dan clicked a moment ago.
    static func confirmMessage(count: Int, reason: DismissReason, runs: [String], dateLabel: String,
                               offeringChoice: Bool = false) -> String {
        // The count is already in the title above this line, so the message spends its words on the thing
        // the title does not carry: the reason every one of them will be filed under.
        //
        // When the sheet offers a second, narrower way forward, this sentence must not pre-commit to the
        // wider one: "They all leave your queue" over a button that deliberately leaves the runs behind
        // describes an outcome Dan has not chosen yet.
        let filed: String
        if offeringChoice {
            filed = "Filed as \(reason.label) either way."
        } else if count == 1 {
            filed = "It leaves your queue, filed as \(reason.label)."
        } else {
            filed = "They all leave your queue, filed as \(reason.label)."
        }
        guard let note = runsNote(runs, dateLabel: dateLabel) else { return filed }
        return "\(filed) \(note)"
    }

    // Names the runs and what dismissing them costs. Phrased as the CONSEQUENCE of the choice rather than
    // as a settled fact, because since Dan's 2026-07-26 follow-up the sheet offers a second button that
    // leaves them alone: "their later nights go too" would describe an outcome he can still decline.
    private static func runsNote(_ runs: [String], dateLabel: String) -> String? {
        guard !runs.isEmpty else { return nil }
        if runs.count == 1 {
            return "\(runs[0]) runs past \(dateLabel), so dismissing it takes its later nights too."
        }
        return "\(list(runs)) run past \(dateLabel), so dismissing them takes their later nights too."
    }

    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.joined() }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    // The proceed button says what it does to what. A bare "OK" on a destructive batch is the control Dan
    // clicks without reading the title above it.
    //
    // With the narrower button beside it, "Dismiss them" stops being clear about WHICH them, so each side
    // of the choice names its own number instead.
    static func confirmProceed(count: Int, offeringChoice: Bool) -> String {
        if offeringChoice { return "Dismiss all \(count)" }
        return count == 1 ? "Dismiss it" : "Dismiss them"
    }

    // The second way out (Dan, 2026-07-26): clear the night of everything that only plays tonight, and
    // leave the runs to be judged on their own.
    static func confirmProceedOnlyThisNight(count: Int) -> String {
        count == 1 ? "Dismiss only that one" : "Dismiss only the \(count)"
    }

    // MARK: - What one Cmd+Z offers to reverse

    // The Edit menu's name for the whole night, e.g. "Undo Dismiss: 5 shows on Jul 24". It names the night
    // rather than one show's org, because a press that brings five shows back must not read like a press
    // that brings one back.
    static func undoLabel(count: Int, dateLabel: String) -> String {
        "\(Plural.count(count, "show")) on \(dateLabel)"
    }
}
