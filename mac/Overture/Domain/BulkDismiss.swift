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
        //
        // #3365: and only for a reason that takes the WHOLE SHOW. Dan's call, 2026-09-02. The narrower
        // button exists to let him clear a night without costing a run its later nights, and under a
        // one-night reason no later night is at stake: the two buttons then differ only in whether the runs
        // lose this night at all, and having just said he cannot shoot anything on it, being offered to
        // leave some of them holding it invites a choice that contradicts the reason he gave.
        func offersChoice(for reason: ShowOutcome) -> Bool {
            BulkDismiss.offersChoice(reason: reason, runsPastTheNight: runsPastTheNight,
                                     keysOnlyThisNight: keysOnlyThisNight)
        }
    }

    // The same question, for a caller holding the plan's two lists rather than the plan (QueueView captures
    // them at the moment Dan picks the reason, so a scout landing between the menu and the button cannot
    // widen what he agreed to). ONE rule, because two copies of it is how the sheet and the buttons come to
    // disagree about whether there is a choice (#863).
    static func offersChoice(reason: ShowOutcome, runsPastTheNight: [String],
                             keysOnlyThisNight: [String]) -> Bool {
        guard !RunNightDrop.isAboutOneNight(reason) else { return false }
        return !runsPastTheNight.isEmpty && !keysOnlyThisNight.isEmpty
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
    static func confirmMessage(count: Int, reason: ShowOutcome, runs: [String], dateLabel: String,
                               offeringChoice: Bool = false) -> String {
        // The count is already in the title above this line, so the message spends its words on the thing
        // the title does not carry: the reason every one of them will be filed under.
        //
        // When the sheet offers a second, narrower way forward, this sentence must not pre-commit to the
        // wider one: "They all leave your queue" over a button that deliberately leaves the runs behind
        // describes an outcome Dan has not chosen yet.
        // #3365: a ONE-NIGHT reason does not take the show. `ProspectMutations.dismissAll` calls
        // `dropNight` for the four reasons in `RunNightDrop.aboutOneNight`, so a run loses this night and
        // comes back under its next one; only a show that played this night ALONE leaves the queue.
        //
        // Dan caught it on the Sep 18 sheet (2026-08-30): "I don't think this is true anymore? Dismissing
        // them doesn't take their later date?" Both sentences were false for that reason. #2691 and #2997
        // corrected the acknowledgements AFTER the fact and this one, the sheet he reads BEFORE deciding,
        // was left describing the old behaviour: it already received `reason` and used it only for the
        // "filed as" clause, never to ask what the reason's SCOPE was.
        //
        // Three branches, not two, because a mixed night is the case an all-or-nothing sentence gets wrong
        // in whichever direction it picks: some of these shows come back and some really are leaving, and
        // the reader cannot tell which from a sentence about "them" (#1547: read every branch, including
        // the ones a fixture rarely reaches).
        if RunNightDrop.isAboutOneNight(reason) {
            return oneNightMessage(count: count, reason: reason, runs: runs, dateLabel: dateLabel,
                                   offeringChoice: offeringChoice)
        }
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

    // #3365: what a one-night reason really does, per shape of the night.
    private static func oneNightMessage(count: Int, reason: ShowOutcome, runs: [String],
                                        dateLabel: String, offeringChoice: Bool) -> String {
        // No run on the night: every show played only this night, so losing it IS leaving. The old
        // sentence was right about this shape all along, which is part of why the defect survived.
        guard !runs.isEmpty else {
            return count == 1
                ? "It leaves your queue, filed as \(reason.label)."
                : "They all leave your queue, filed as \(reason.label)."
        }
        let others = count - runs.count
        // Every show on the night is a run, so nothing leaves at all. Said in the negative, because "they
        // lose Sep 18" alone reads as a loss and the thing worth knowing is that he gets them all back.
        guard others > 0 else {
            return count == 1
                ? "It loses \(dateLabel), filed as \(reason.label), and turns up again under its next night."
                : "They all lose \(dateLabel), filed as \(reason.label), and turn up again under their next night."
        }
        // Mixed: name the runs, then say plainly what happens to the rest.
        //
        // Four whole literals rather than one built from a stem and a clause. The copy inventory lists each
        // literal on its own, so a sentence assembled in halves reaches the cold read in halves and the
        // line Dan actually meets appears nowhere (#843's own failure mode).
        switch (runs.count == 1, others == 1) {
        case (true, true):
            return "They lose \(dateLabel), filed as \(reason.label). \(runs[0]) plays on past \(dateLabel) and turns up again under its next night; the other one leaves your queue."
        case (true, false):
            return "They lose \(dateLabel), filed as \(reason.label). \(runs[0]) plays on past \(dateLabel) and turns up again under its next night; the rest leave your queue."
        case (false, true):
            return "They lose \(dateLabel), filed as \(reason.label). \(list(runs)) play on past \(dateLabel) and turn up again under their next night; the other one leaves your queue."
        case (false, false):
            return "They lose \(dateLabel), filed as \(reason.label). \(list(runs)) play on past \(dateLabel) and turn up again under their next night; the rest leave your queue."
        }
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

    // #2063: Plural.list, shared with ClockTime and the reply card rather than a private third copy.
    private static func list(_ names: [String]) -> String { Plural.list(names) }

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
