import Foundation

// Keeps repeat-client recognition current without a stale CSV re-import (#19). The
// matching history is derived live from Overture's own activity: an org it has emailed
// is "contacted", a booked outcome is "booked". Merged with Downbeat (canonical booked,
// passed separately) and any one-time legacy import, so every send Dan makes feeds the
// next scout's prior-relationship signal automatically.
enum LocalHistory {
    // Reasons Dan skips a prospect because HE couldn't take it (a scheduling miss), not because
    // they're a bad fit — these stay hot future leads (1.2 / #70).
    private static let schedulingDismissals: Set<DismissReason> = [.dateConflict, .dayDoesntWork, .alreadyBooked]

    static func records(from prospects: [Prospect]) -> [HistoryRecord] {
        prospects.compactMap { p in
            if p.outcome == .booked {
                return HistoryRecord(groupName: p.groupName, status: "booked")
            }
            if p.status == .dismissed,
               let reason = DismissReason(rawValue: p.dismissReasonRaw ?? ""),
               schedulingDismissals.contains(reason) {
                return HistoryRecord(groupName: p.groupName, status: "declined")
            }
            if p.outcome == .replied {
                return HistoryRecord(groupName: p.groupName, status: "warm")
            }
            if p.sentAt != nil {
                return HistoryRecord(groupName: p.groupName, status: "contacted")
            }
            return nil
        }
    }
}
