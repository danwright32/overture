import Foundation

// #1219: warn when Dan is about to prep or send a pitch for a show whose performance date matches a date
// he has ALREADY COMMITTED a DIFFERENT show on, so he does not accidentally book two shoots on one night.
// This is distinct from the external-calendar conflict (BlockedCalendar): that compares a date against
// Downbeat bookings and days off; this compares two different Overture prospects to each other.
//
// Pure and testable: the caller maps its prospects/queue rows into `Show` values (identity, the nights it
// plays, whether the show is a commitment, engagement link, and a display name) and asks for the OTHER
// committed shows that clash on any shared night. No SwiftData here.
enum SelfBookingConflict {
    struct Show: Equatable {
        let key: String              // stable identity (naturalKey), so a show never conflicts with itself
        // #3323: EVERY night this show plays, not its opening night. A run is ONE row carrying a span and
        // a night list (`Prospect.runNights`), so comparing `performanceDate` alone made nights two onward
        // invisible. Measured on the live store 2026-09-01, that missed 14 of the 30 live-versus-committed
        // collisions in the queue, across 13 rows, both masking rows colliding on a night that was nobody's
        // opening.
        //
        // EMPTY never collides, and the fallback to `performanceDate` alone belongs to the CALLER
        // (QueueModel.selfBookingShow). Deliberately not BlockedCalendar's span walk: that one is right for
        // a blocked day, where clearing a real clash on no evidence is the direction that loses safety, and
        // wrong here, where walking a span would manufacture a clash on the dark nights of a weekly series.
        let nights: [String]
        // #1219: this show counts as a same-night COMMITMENT (a booked shoot, a pitch already emailed, or a
        // live draft/approved) rather than a dead-dismissed or untouched candidate. The caller decides the
        // predicate (QueueModel.selfBookingIsCommitment); single tier, so any commitment intervenes the
        // same way.
        let isCommitment: Bool
        // The shared production id: the same run touring venues is one show, not a double-booking.
        //
        // #3323: read through GroupNameMatch.normalize, NOT as raw display text, because that is the fold
        // `EngagementLink` itself uses to decide two rows are one engagement (EngagementLink.swift:39). Two
        // definitions of "the same production" would drift (L263), and raw text is the one that breaks
        // under expansion: a run whose per-night sibling the scout renamed shares EVERY night with itself,
        // so raw equality would have the card clash with itself on all of them and warn forever (L36).
        // What that costs, stated rather than discovered: `normalize` strips a trailing subtitle, so two
        // different programs a presenter gives on one night fold together and are exempt. That is not a new
        // judgement, it is the one EngagementLink already makes about those rows everywhere else. Measured
        // 2026-08-30: zero committed pairs in the live store are exempt under either spelling, so the
        // correction is free today and expensive later.
        let engagementKey: String?
        let name: String             // display name (groupName), so a warning can name the other show
        // #1699 part 3 / #3323: the curtain time(s) this show plays, keyed by NIGHT, as 24-hour "HH:mm".
        //
        // Per night rather than per show, because a run's nights genuinely differ (`Prospect.startTimesVary`
        // exists because 16 of 30 timed cards on the two live ticketing venues could not state one time for
        // the whole run). This is the one place expansion could produce a wrong REASSURANCE rather than a
        // wrong warning: a Saturday matinee's eight-hour gap must not quiet a Tuesday clash fifteen minutes
        // apart, which a single per-show list would have let it do.
        //
        // A night with no entry is the ordinary state and means nobody published a time for it, which is
        // the MAJORITY of shows: only the three native ticketing/Squarespace readers state a time at all.
        let timesByNight: [String: [String]]
    }

    // #3323: one collision, on ONE named night. The night has to come back with the show: every sentence
    // downstream renders under a header keyed to the card's opening night, so a clash reported without its
    // night would make a claim the check never measured (L263). #1501 is the same problem solved on the
    // blocked-calendar half, where a clash on Jul 31 read as a claim about the Jul 24 header above it.
    struct Overlap: Equatable {
        let night: String
        let other: Show
    }

    // #1699 part 3, Dan's number (2026-08-03): five hours between curtains is a night he can work twice.
    static let workableGapMinutes = 5 * 60

    // Committed shows grouped by night, built ONCE for a render pass rather than once per row.
    //
    // #3323 section 1.5: `selfBookingConflicts` maps the whole rendered set into `Show` values per row, and
    // QueueView calls it per item. Multiplying that by up to 23 nights without an index is a measurable
    // regression on the surface Dan lives in, and #1772 is this repo already having paid for exactly that
    // shape once. Built in `QueueRenderPass`, beside `agentInputs` and `gmailConnected`, for the same
    // reason those are (#1770, #1771).
    struct NightIndex {
        fileprivate let committedByNight: [String: [Show]]

        init(_ shows: [Show]) {
            var byNight: [String: [Show]] = [:]
            for show in shows where show.isCommitment {
                for night in Set(show.nights) { byNight[night, default: []].append(show) }
            }
            committedByNight = byNight
        }
    }

    // Every OTHER committed show sharing one of `target`'s nights, one entry PER SHARED NIGHT, whatever the
    // clock says.
    //
    // Only the OTHER shows' commitment matters, not the target's: a kept show being prepped still needs to
    // see an already-committed show on any of its nights.
    //
    // The single predicate behind BOTH lists below, so the shows that warn and the shows that merely note
    // themselves can never disagree about which shows are on the night at all (L16).
    //
    // Ordered by night, then by key: a total order that does not depend on the input array, so the index
    // and the direct comparison cannot return the same collisions in different orders, and a rendered list
    // cannot reshuffle between redraws.
    static func sameNight(for target: Show, among all: [Show]) -> [Overlap] {
        overlaps(for: target) { night in all.filter { $0.isCommitment && $0.nights.contains(night) } }
    }

    // The same question against a prebuilt index. Same predicate, same order, same answer.
    static func sameNight(for target: Show, in index: NightIndex) -> [Overlap] {
        overlaps(for: target) { index.committedByNight[$0] ?? [] }
    }

    private static func overlaps(for target: Show,
                                 committedOn: (String) -> [Show]) -> [Overlap] {
        // Deduplicated on read: 15 rows in the live store hold the same night twice (2026-09-01, an
        // upstream fold defect with its own owner), and without this each of them raises every clash twice.
        var found: [Overlap] = []
        for night in Set(target.nights).sorted() {
            for other in committedOn(night) where isADifferentShow(other, from: target) {
                found.append(Overlap(night: night, other: other))
            }
        }
        return found.sorted { ($0.night, $0.other.key) < ($1.night, $1.other.key) }
    }

    private static func isADifferentShow(_ other: Show, from target: Show) -> Bool {
        guard other.key != target.key else { return false }
        guard let mine = normalizedEngagement(target.engagementKey),
              let theirs = normalizedEngagement(other.engagementKey) else { return true }
        return mine != theirs
    }

    // Nil when the key is absent or normalizes to nothing at all, so two shows whose names are pure
    // punctuation are not folded into one engagement by an empty string matching an empty string.
    private static func normalizedEngagement(_ key: String?) -> String? {
        guard let key else { return nil }
        let folded = GroupNameMatch.normalize(key)
        return folded.isEmpty ? nil : folded
    }

    // The OTHER committed shows that CLASH with `target`, per night (empty = every night is clear).
    //
    // #1699 part 3: a show on the same night is a clash unless the published times PROVE Dan can work
    // both. That proof is the narrow case, not the broad one: it needs a readable time on each side FOR
    // THAT NIGHT and every pairing across them clearing the gap. A night nobody published a time for warns
    // exactly as it did before this existed, which is most nights.
    static func conflicts(for target: Show, among all: [Show]) -> [Overlap] {
        sameNight(for: target, among: all).filter { isAClash(target, $0) }
    }

    static func conflicts(for target: Show, in index: NightIndex) -> [Overlap] {
        sameNight(for: target, in: index).filter { isAClash(target, $0) }
    }

    // The OTHER committed shows on a night that the clock proves are workable alongside `target`.
    // Not a warning: Dan still wants to know the night is doubled up, without being asked to confirm.
    static func workable(for target: Show, among all: [Show]) -> [Overlap] {
        sameNight(for: target, among: all).filter { !isAClash(target, $0) }
    }

    static func workable(for target: Show, in index: NightIndex) -> [Overlap] {
        sameNight(for: target, in: index).filter { !isAClash(target, $0) }
    }

    // #3323: whether every clash across a date GROUP falls on that group's own date. The date-header note
    // sits under a header naming one date, so it may only say "on this date" when that is true; a run in
    // the group clashing on a later night makes the sentence read as a claim about the header (#1501).
    //
    // True when there are no clashes at all: the caller decides whether to show a note, and a group with
    // nothing to report must not push it into the run wording.
    static func everyClashIsOn(_ date: String, for group: [Show], in index: NightIndex) -> Bool {
        group.allSatisfy { show in conflicts(for: show, in: index).allSatisfy { $0.night == date } }
    }

    private static func isAClash(_ target: Show, _ overlap: Overlap) -> Bool {
        gapMinutes(between: target, and: overlap.other, on: overlap.night) == nil
    }

    // Minutes between the CLOSEST pair of curtains ON THAT NIGHT, or nil when the night cannot be proven
    // workable.
    //
    // Nil on every uncertainty, because only a measured gap may quiet a warning:
    //  - either side published no time for THIS night ("nobody said" is not "they are far apart");
    //  - any stated time does not read, so the schedule as a whole is not understood (dropping just the
    //    bad one would leave the survivors looking like the complete list, L11);
    //  - any single pairing falls inside the gap, so a double bill's far performance cannot excuse its
    //    near one (#1984: 24 of 274 rows on the watched OvationTix venues play twice in a day).
    //
    // #3323: `on night` is not optional and has no default. A gap is a fact about one night, and a caller
    // that could omit the night would silently be asking about the show as a whole again, which is the
    // defect this change exists to remove.
    static func gapMinutes(between target: Show, and other: Show, on night: String) -> Int? {
        guard let a = minutes(target.timesByNight[night] ?? []),
              let b = minutes(other.timesByNight[night] ?? []) else { return nil }
        var closest = Int.max
        for x in a {
            for y in b { closest = min(closest, abs(x - y)) }
        }
        return closest >= workableGapMinutes ? closest : nil
    }

    // A show's published schedule FOR ONE NIGHT as minutes since midnight, or nil if it published none or
    // if any one of its times is unreadable. All-or-nothing on purpose: a partly understood schedule is not
    // a schedule, and it must land on the side that keeps warning (L50).
    private static func minutes(_ startTimes: [String]) -> [Int]? {
        guard !startTimes.isEmpty else { return nil }
        let parsed = startTimes.compactMap(ClockTime.minutesOfDay)
        return parsed.count == startTimes.count ? parsed : nil
    }

    // Whether every one of `other`'s curtains on this night falls before all of `target`'s (true) or after
    // all of them (false). Nil when they straddle it and no one side is honestly stateable, which needs one
    // show playing performances more than the gap apart on a single day; not observed, but the sentence
    // must not claim a direction it did not measure.
    static func isBefore(_ other: Show, than target: Show, on night: String) -> Bool? {
        guard let a = minutes(target.timesByNight[night] ?? []),
              let b = minutes(other.timesByNight[night] ?? []),
              let earliestTarget = a.min(), let latestTarget = a.max(),
              let earliestOther = b.min(), let latestOther = b.max() else { return nil }
        if latestOther < earliestTarget { return true }
        if earliestOther > latestTarget { return false }
        return nil
    }
}

// #1219: one prepping show that sits on a night already holding a committed OTHER show, with the names of
// the shows it clashes with. Produced by QueueModel.selfBookingPrepClashes for the prep-launch confirm.
struct SelfBookingPrepClash: Equatable {
    let groupName: String        // the show about to be prepped
    let conflictNames: [String]  // the committed other shows on its night
    // #3323: the night the clash was actually found on, and the night this card is filed under, so the
    // confirm can say WHICH night of a run is the problem rather than implying it is the card's own.
    let clashNight: String?
    let performanceDate: String?
}

// #1219 copy. Kept out of the views (testable, #885) and named so the copy-inventory shows the whole
// sentence Dan reads. Every user-facing line NAMES the clashing show(s) so he remembers which one; a
// blank groupName reads as "another show".
enum SelfBookingCopy {
    // The queue-wide date-header flag. A short date-level note; the per-row marker names the specifics.
    //
    // #3323: two sentences, not one. The note is drawn under a header naming ONE date, and since the check
    // reads every night of a run the clash it reports may be days after that date. "on this date" would
    // then be a claim the check never measured, sitting directly under the date it appears to be about.
    // That is #1501's defect exactly, on the other half of the system: the sentence was true and read
    // false, because the eye binds the date in the sentence to the header above it.
    static func dateHeaderNote(allOnThisDate: Bool) -> String {
        allOnThisDate
            ? "Another pitch is already in progress on this date"
            : "Another pitch is already in progress on a night one of these runs plays"
    }

    // The prep-launch confirm: shown before a Prep run when one or more of the shows being prepped sit on a
    // night that already holds a committed pitch, so Dan confirms past a possible double-booking deliberately.
    static let prepConfirmTitle = "Prep a show on a date you're already pitching?"
    static let prepConfirmProceed = "Prep anyway"
    static func prepConfirmMessage(_ clashes: [SelfBookingPrepClash]) -> String? {
        guard !clashes.isEmpty else { return nil }
        let lines = clashes.map { clash -> String in
            let show = clash.groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "This show" : clash.groupName
            let others = othersPhrase(clash.conflictNames) ?? "another show"
            // A LATER night gets its own sentence rather than a clause appended to the one above.
            // "\(show) is on a date ... for \(others), on Oct 29." opens by talking about the card's
            // date and closes by naming a different one, so it reads as two competing dates.
            switch laterNight(clashNight: clash.clashNight, performanceDate: clash.performanceDate) {
            case .thisNight:
                return "\(show) is on a date you already have a pitch in progress for \(others)."
            case .named(let label):
                return "\(show) plays \(label), when you already have a pitch in progress for \(others)."
            case .unnamed:
                return "\(show) plays a later night of its run when you already have a pitch in progress for \(others)."
            }
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

    // #3323: how a clash on a LATER night of a run is named, or nil when the clash is on the card's own
    // night and the existing wording is already true.
    //
    // Three states, never two. An unreadable or absent night may NOT fall back to "on this date": that
    // sentence would land under a date header naming a different night and assert something the check never
    // measured, which is worse than naming no night at all (L11). It says the clash is later in the run
    // instead, which is the most specific true thing available.
    enum NightScope: Equatable {
        case thisNight              // the clash is on the night the card is filed under
        case named(String)          // a later night, and it reads: "Oct 29"
        case unnamed                // a later night whose date could not be read
    }

    static func laterNight(clashNight: String?, performanceDate: String?) -> NightScope {
        if let clashNight, let performanceDate,
           ConflictScope.of(blockedDate: clashNight, performanceDate: performanceDate) == .thisNight {
            return .thisNight
        }
        // Nothing measured at all: no clash night AND no card date. There is no run to speak of, so this
        // reads as the ordinary same-date case rather than inventing a later night nobody found.
        if clashNight == nil, performanceDate == nil { return .thisNight }
        guard let clashNight, let label = EasternDate.dayLabel(clashNight) else { return .unnamed }
        return .named(label)
    }


    // The persistent marker on a show's own row while Dan scans a stage.
    //
    // Assembled as whole literals per branch, never concatenated from halves: the copy inventory lists each
    // literal separately, so a sentence built in pieces reaches the cold read in pieces and the line Dan
    // actually meets appears nowhere (#843's own failure mode).
    static func rowMarker(_ names: [String], clashNight: String?, performanceDate: String?) -> String? {
        guard let others = othersPhrase(names) else { return nil }
        switch laterNight(clashNight: clashNight, performanceDate: performanceDate) {
        case .thisNight:
            return "Also pitching \(others) on this date"
        case .named(let label):
            return "Also pitching \(others) on \(label)"
        case .unnamed:
            return "Also pitching \(others) on a later night of this run"
        }
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
                                  others: [SelfBookingConflict.Overlap]) -> String? {
        guard let first = others.first else { return nil }
        let name = first.other.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "another show" : first.other.name
        guard let times = ClockTime.listLabel(first.other.timesByNight[first.night] ?? []) else { return nil }
        // Several workable shows cannot share one gap, so the clause is dropped rather than stating a
        // number true of only the first. Same "and N others" shape the warning already uses.
        guard others.count == 1 else {
            let rest = others.count - 1
            return "Also pitching \(name) at \(times) and \(rest) other\(rest == 1 ? "" : "s")"
        }
        guard let gap = SelfBookingConflict.gapMinutes(between: target, and: first.other, on: first.night),
              let before = SelfBookingConflict.isBefore(first.other, than: target, on: first.night) else {
            return "Also pitching \(name) at \(times)"
        }
        // Floored, never rounded up: the line may only claim room that was actually measured.
        let hours = gap / 60
        let plural = hours == 1 ? "" : "s"
        let side = before ? "before" : "after"
        return "Also pitching \(name) at \(times), \(hours) hour\(plural) \(side) this one"
    }

    // The confirm-to-proceed warning shown at Prep-launch and at Send.
    static func confirmWarning(_ names: [String], clashNight: String?,
                               performanceDate: String?) -> String? {
        guard let others = othersPhrase(names) else { return nil }
        switch laterNight(clashNight: clashNight, performanceDate: performanceDate) {
        case .thisNight:
            return "You already have a pitch in progress for \(others) on this date."
        case .named(let label):
            return "You already have a pitch in progress for \(others) on \(label)."
        case .unnamed:
            return "You already have a pitch in progress for \(others) on a later night of this run."
        }
    }
}
