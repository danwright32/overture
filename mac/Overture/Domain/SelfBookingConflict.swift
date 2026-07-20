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
    }

    // The OTHER committed shows that clash with `target` on its EXACT date, in the input order (empty = the
    // date is clear). Only the OTHER shows' commitment matters, not the target's: a kept show being prepped
    // still needs to see an already-committed show on its date. Exact date match only (#1219 decision 3):
    // multi-night runs are separate per-date rows, so a shared night still collides without expanding
    // runEndDate spans.
    static func conflicts(for target: Show, among all: [Show]) -> [Show] {
        guard let date = target.date else { return [] }
        return all.filter { other in
            other.key != target.key
                && other.isCommitment
                && other.date == date
                // The same linked production (a run touring venues) is one show, not a double-booking.
                && !(target.engagementKey != nil && other.engagementKey == target.engagementKey)
        }
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

    // The confirm-to-proceed warning shown at Prep-launch and at Send.
    static func confirmWarning(_ names: [String]) -> String? {
        othersPhrase(names).map { "You already have a pitch in progress for \($0) on this date." }
    }
}
