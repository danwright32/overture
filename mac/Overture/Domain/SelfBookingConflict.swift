import Foundation

// #1219: warn when Dan is about to prep or send a pitch for a show whose performance date matches a date
// he has ALREADY COMMITTED a DIFFERENT show on, so he does not accidentally book two shoots on one night.
// This is distinct from the external-calendar conflict (BlockedCalendar): that compares a date against
// Downbeat bookings and days off; this compares two different Overture prospects to each other.
//
// Pure and testable: the caller maps its prospects/queue rows into `Show` values (identity, date, whether
// the show is a commitment, engagement link, and a display name) and asks for the OTHER committed shows
// that clash on the exact date. No SwiftData here.
enum SelfBookingConflict {
    struct Show: Equatable {
        let key: String              // stable identity (naturalKey), so a show never conflicts with itself
        let date: String?            // performanceDate; nil never collides
        // #1219: this show counts as a same-date COMMITMENT (a booked shoot, a pitch already emailed, or a
        // live draft/approved) rather than a dead-dismissed or untouched candidate. The caller decides the
        // predicate (QueueModel.selfBookingShow); single tier, so any commitment intervenes the same way.
        let isCommitment: Bool
        let engagementKey: String?   // shared production id (EngagementLink); the same run is one show
        let name: String             // display name (groupName), so a warning can name the other show
        // #1699 part 3: the curtain time(s) this show plays on THIS date, as 24-hour "HH:mm".
        //
        // EMPTY is the ordinary state and means nobody published one, which is the MAJORITY of shows:
        // only the three native ticketing/Squarespace readers state a time at all. Deliberately not
        // optional and deliberately not defaulted, so every caller has to say what it knows rather than
        // inheriting a silence it never thought about.
        let startTimes: [String]
    }

    // #1699 part 3, Dan's number (2026-08-03): five hours between curtains is a night he can work twice.
    static let workableGapMinutes = 5 * 60

    // Every OTHER committed show sharing `target`'s EXACT date, whatever the clock says. Only the OTHER
    // shows' commitment matters, not the target's: a kept show being prepped still needs to see an
    // already-committed show on its date. Exact date match only (#1219 decision 3): multi-night runs are
    // separate per-date rows, so a shared night still collides without expanding runEndDate spans.
    //
    // The single predicate behind BOTH lists below, so the shows that warn and the shows that merely note
    // themselves can never disagree about which shows are on the night at all (L16).
    static func sameNight(for target: Show, among all: [Show]) -> [Show] {
        guard let date = target.date else { return [] }
        return all.filter { other in
            other.key != target.key
                && other.isCommitment
                && other.date == date
                // The same linked production (a run touring venues) is one show, not a double-booking.
                && !(target.engagementKey != nil && other.engagementKey == target.engagementKey)
        }
    }

    // The OTHER committed shows that CLASH with `target`, in the input order (empty = the date is clear).
    //
    // #1699 part 3: a show on the same night is a clash unless the published times PROVE Dan can work
    // both. That proof is the narrow case, not the broad one: it needs a readable time on each side and
    // every pairing across them clearing the gap. A night nobody published a time for warns exactly as it
    // did before this existed, which is most nights.
    static func conflicts(for target: Show, among all: [Show]) -> [Show] {
        sameNight(for: target, among: all).filter { gapMinutes(between: target, and: $0) == nil }
    }

    // The OTHER committed shows on this night that the clock proves are workable alongside `target`.
    // Not a warning: Dan still wants to know the night is doubled up, without being asked to confirm.
    static func workable(for target: Show, among all: [Show]) -> [Show] {
        sameNight(for: target, among: all).filter { gapMinutes(between: target, and: $0) != nil }
    }

    // Minutes between the CLOSEST pair of curtains, or nil when the night cannot be proven workable.
    //
    // Nil on every uncertainty, because only a measured gap may quiet a warning:
    //  - either side published no time at all ("nobody said" is not "they are far apart");
    //  - any stated time does not read, so the schedule as a whole is not understood (dropping just the
    //    bad one would leave the survivors looking like the complete list, L11);
    //  - any single pairing falls inside the gap, so a double bill's far performance cannot excuse its
    //    near one (#1984: 24 of 274 rows on the watched OvationTix venues play twice in a day).
    static func gapMinutes(between target: Show, and other: Show) -> Int? {
        guard let a = minutes(target.startTimes), let b = minutes(other.startTimes) else { return nil }
        var closest = Int.max
        for x in a {
            for y in b { closest = min(closest, abs(x - y)) }
        }
        return closest >= workableGapMinutes ? closest : nil
    }

    // A show's whole published schedule as minutes since midnight, or nil if it published none or if any
    // one of its times is unreadable. All-or-nothing on purpose: a partly understood schedule is not a
    // schedule, and it must land on the side that keeps warning (L50).
    private static func minutes(_ startTimes: [String]) -> [Int]? {
        guard !startTimes.isEmpty else { return nil }
        let parsed = startTimes.compactMap(ClockTime.minutesOfDay)
        return parsed.count == startTimes.count ? parsed : nil
    }

    // Whether every one of `other`'s curtains falls before all of `target`'s (true) or after all of them
    // (false). Nil when they straddle it and no one side is honestly stateable, which needs one show
    // playing performances more than the gap apart on a single day; not observed, but the sentence must
    // not claim a direction it did not measure.
    static func isBefore(_ other: Show, than target: Show) -> Bool? {
        guard let a = minutes(target.startTimes), let b = minutes(other.startTimes),
              let earliestTarget = a.min(), let latestTarget = a.max(),
              let earliestOther = b.min(), let latestOther = b.max() else { return nil }
        if latestOther < earliestTarget { return true }
        if earliestOther > latestTarget { return false }
        return nil
    }
}

// #1219: one prepping show that sits on a date already holding a committed OTHER show, with the names of
// the shows it clashes with. Produced by QueueModel.selfBookingPrepClashes for the prep-launch confirm.
struct SelfBookingPrepClash: Equatable {
    let groupName: String        // the show about to be prepped
    let conflictNames: [String]  // the committed other shows on its date
}

// #1219 copy. Kept out of the views (testable, #885) and named so the copy-inventory shows the whole
// sentence Dan reads. Every user-facing line NAMES the clashing show(s) so he remembers which one; a
// blank groupName reads as "another show".
enum SelfBookingCopy {
    // The queue-wide date-header flag. A short date-level note; the per-row marker names the specifics.
    static let dateHeaderNote = "Another pitch is already in progress on this date"

    // The prep-launch confirm: shown before a Prep run when one or more of the shows being prepped sit on a
    // date that already holds a committed pitch, so Dan confirms past a possible double-booking deliberately.
    static let prepConfirmTitle = "Prep a show on a date you're already pitching?"
    static let prepConfirmProceed = "Prep anyway"
    // #1219: Approve is a third committing moment Dan gated (like Prep-launch and Send). Same dialog, its
    // own verb.
    static let approveConfirmTitle = "Approve a show on a date you're already pitching?"
    static let approveConfirmProceed = "Approve anyway"
    static func prepConfirmMessage(_ clashes: [SelfBookingPrepClash]) -> String? {
        guard !clashes.isEmpty else { return nil }
        let lines = clashes.map { clash -> String in
            let show = clash.groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "This show" : clash.groupName
            let others = othersPhrase(clash.conflictNames) ?? "another show"
            return "\(show) is on a date you already have a pitch in progress for \(others)."
        }
        return lines.joined(separator: "\n")
    }

    // "Orchestra A", or "Orchestra A and 2 others" for several; a blank name becomes "another show".
    static func othersPhrase(_ names: [String]) -> String? {
        let cleaned = names.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "another show" : $0
        }
        guard let first = cleaned.first else { return nil }
        guard cleaned.count > 1 else { return first }
        let rest = cleaned.count - 1
        return "\(first) and \(rest) other\(rest == 1 ? "" : "s")"
    }

    // The persistent marker on a show's own row while Dan scans a stage.
    static func rowMarker(_ names: [String]) -> String? {
        othersPhrase(names).map { "Also pitching \($0) on this date" }
    }

    // #1699 part 3: the same night, when the published times prove Dan can work both shows.
    //
    // Not a warning and not styled as one: nothing asks him to confirm past it, because there is nothing
    // to confirm. It exists because going fully silent would take away the fact that the night is doubled
    // up at all, which he still wants to see (his call, 2026-08-03, choosing from the rendered options).
    //
    // The sentence names the gap itself, because the gap is the whole reason this is a note rather than a
    // warning, and reading it saves doing the arithmetic between two times.
    static func workableRowMarker(target: SelfBookingConflict.Show,
                                  others: [SelfBookingConflict.Show]) -> String? {
        guard let first = others.first else { return nil }
        let name = first.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "another show" : first.name
        guard let times = ClockTime.listLabel(first.startTimes) else { return nil }
        // Several workable shows cannot share one gap, so the clause is dropped rather than stating a
        // number true of only the first. Same "and N others" shape the warning already uses.
        guard others.count == 1 else {
            let rest = others.count - 1
            return "Also pitching \(name) at \(times) and \(rest) other\(rest == 1 ? "" : "s")"
        }
        guard let gap = SelfBookingConflict.gapMinutes(between: target, and: first),
              let before = SelfBookingConflict.isBefore(first, than: target) else {
            return "Also pitching \(name) at \(times)"
        }
        // Floored, never rounded up: the line may only claim room that was actually measured.
        let hours = gap / 60
        // Assembled as ONE literal, never concatenated: the copy inventory lists each literal
        // separately, so a sentence built in halves reaches the cold read in halves and the line Dan
        // actually meets appears nowhere (#843's own failure mode).
        let plural = hours == 1 ? "" : "s"
        let side = before ? "before" : "after"
        return "Also pitching \(name) at \(times), \(hours) hour\(plural) \(side) this one"
    }

    // The confirm-to-proceed warning shown at Prep-launch and at Send.
    static func confirmWarning(_ names: [String]) -> String? {
        othersPhrase(names).map { "You already have a pitch in progress for \($0) on this date." }
    }
}
