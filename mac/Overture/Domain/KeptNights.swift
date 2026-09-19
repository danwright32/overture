import Foundation

// #3326, plan 4.1 and 4.2: which nights of a run an email may name, and how it names them.
//
// Dan's answer 2, 2026-09-17: the email names the KEPT dates, spans them only when they are contiguous AND
// more than three, and may NEVER name a night he skipped. The rule's two moving parts, the threshold and
// the contiguity test, live HERE and nowhere else. The drafter is not told the rule's arithmetic; it is
// told the answer for each item (`PrepQueueItem.keptNightsAsSpan`), so the runbook, the brand voice skill
// and both halves of the draft check can never hold five copies of "more than three" (L41, L70, L263).
//
// #3312: which wins, chronology or Dan's ticks? CHRONOLOGY, declared here and derived everywhere else. A
// night already behind us cannot be shot, so it is never offered by the picker (`PrepNightPlan.build`),
// never kept here, and `PrepQueueItem.openingNightPassed` is the same `upcoming` fact seen from the
// opening night. `KeptNightsAgreeWithChronologyTests` fails if the two ever disagree.
enum KeptNights {

    // "More than three": a span is allowed from four contiguous nights up.
    static let spanThreshold = 3

    // The nights of a recorded run still ahead of `today`, in order. Nil for a row whose nights were never
    // recorded or that has no date: for those there is no per-night answer to give, and the drafter keeps
    // the old run-span rule.
    static func upcoming(_ playing: PlayingNights, today: String) -> [String]? {
        guard case .recorded(let nights) = playing else { return nil }
        return nights.filter { $0 >= today }
    }

    // The nights the email may name: every upcoming night of a MULTI-night recorded run that Dan did not
    // skip. A night nobody has judged yet is kept, because the default is pitch every night (answer 1).
    // Nil for a single-night show and for a run with nothing left ahead, which keep today's behaviour.
    static func of(_ playing: PlayingNights, skipped: Set<String>, today: String) -> [String]? {
        guard case .recorded(let all) = playing, all.count > 1,
              let ahead = upcoming(playing, today: today) else { return nil }
        let kept = ahead.filter { !skipped.contains($0) }
        return kept.isEmpty ? nil : kept
    }

    @MainActor
    static func of(_ p: Prospect, today: String) -> [String]? {
        of(p.playingNights, skipped: Set(p.skippedNightDecisions.map(\.night)), today: today)
    }

    // #3326 (plan 2.8): the skipped night these words name, or nil. The same finding the draft review
    // shows, asked of the exact text about to leave, so the send refuses what the screen refused (L109).
    @MainActor
    static func skippedNightNamed(subject: String?, body: String, on p: Prospect, today: String) -> String? {
        let finding = EventDateInDraft.finding(subject: subject, body: body,
                                               performanceDate: p.performanceDate, runEndDate: p.runEndDate,
                                               today: today, kept: of(p, today: today),
                                               skipped: p.skippedNightDecisions.map(\.night))
        guard case .namesASkippedNight(_, let night)? = finding else { return nil }
        return night
    }

    // Every night the day after the one before.
    static func isContiguous(_ nights: [String]) -> Bool {
        let sorted = nights.sorted()
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            guard let d = EasternDate.date(from: a),
                  let next = EasternDate.calendar.date(byAdding: .day, value: 1, to: d),
                  EasternDate.dayString(from: next) == b else { return false }
        }
        return true
    }

    // Whether the email may name these nights as a span ("November 10 to 14") rather than one by one.
    static func namesAsSpan(_ nights: [String]) -> Bool {
        nights.count > spanThreshold && isContiguous(nights)
    }
}
