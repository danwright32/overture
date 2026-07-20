import Foundation

// #1219: warn when Dan is about to prep or send a pitch for a show whose performance date matches a
// date he has ALREADY pitched a DIFFERENT show on, so he does not accidentally commit to two shoots on
// one night. This is distinct from the external-calendar conflict (BlockedCalendar): that compares a
// date against Downbeat bookings and days off; this compares two different Overture prospects to each
// other.
//
// Pure and testable: the caller maps its prospects/queue rows into `Show` values (identity, date, pitch
// state, engagement link) and asks for the strongest conflict. No SwiftData here.
enum SelfBookingConflict {
    // How firmly a same-date collision intervenes (#1219 decision 1 + 2):
    //   .emailed  a DIFFERENT show already EMAILED on this date. The strong case: it blocks prep and send
    //             (a deliberate override is required, like the salutation-review/draft-lint blocks).
    //   .drafted  a DIFFERENT show only DRAFTED (not yet sent) on this date. The soft case: a passive
    //             note, never a block.
    // Emailed outranks drafted when both are present, so the surfaced warning reflects the real stakes.
    enum Strength: Equatable { case emailed, drafted }

    struct Show: Equatable {
        let key: String              // stable identity (naturalKey), so a show never conflicts with itself
        let date: String?            // performanceDate; nil never collides
        let emailed: Bool            // at least one recipient actually sent (Prospect.sentAt / gmailMessageId)
        let drafted: Bool            // has a draft but has not been emailed
        let engagementKey: String?   // shared production id (EngagementLink); the same run is one show, not a clash
    }

    // The strongest same-date conflict for `target` from a DIFFERENT show among `all`, or nil. Exact date
    // match only (#1219 decision 3): multi-night runs are already separate per-date rows, so a shared
    // night still collides here without expanding runEndDate spans.
    static func conflict(for target: Show, among all: [Show]) -> Strength? {
        guard let date = target.date else { return nil }
        let clashes = all.filter { other in
            other.key != target.key
                && other.date == date
                // The same linked production (a run touring venues) is one show, not a double-booking.
                && !(target.engagementKey != nil && other.engagementKey == target.engagementKey)
        }
        if clashes.contains(where: \.emailed) { return .emailed }
        if clashes.contains(where: \.drafted) { return .drafted }
        return nil
    }
}
