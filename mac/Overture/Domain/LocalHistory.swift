import Foundation

// Keeps repeat-client recognition current without a stale CSV re-import (#19). The
// matching history is derived live from Overture's own activity: a booked outcome is
// "booked", a reply is "warm", a scheduling dismissal is "declined", a lost outcome is
// "lost_soft"/"lost_hard", and a plain send is a neutral "contacted". Merged with
// Downbeat and any one-time legacy import, so every action Dan takes feeds the next
// scout's prior-relationship signal automatically.
enum LocalHistory {
    // Reasons Dan skips a prospect because HE couldn't take it (a scheduling miss), not because
    // they're a bad fit; these stay hot future leads (1.2 / #70).
    private static let schedulingDismissals: Set<DismissReason> = [.dateConflict, .dayDoesntWork, .alreadyBooked]

    static func records(from prospects: [Prospect]) -> [HistoryRecord] {
        prospects.compactMap { p in
            if p.outcome == .booked {
                return HistoryRecord(groupName: p.groupName, status: "booked")
            }
            if p.outcome == .lostHard {
                return HistoryRecord(groupName: p.groupName, status: "lost_hard")
            }
            if p.outcome == .lostSoft {
                return HistoryRecord(groupName: p.groupName, status: "lost_soft")
            }
            if p.status == .dismissed,
               let reason = DismissReason(rawValue: p.dismissReasonRaw ?? ""),
               schedulingDismissals.contains(reason) {
                return HistoryRecord(groupName: p.groupName, status: "declined")
            }
            // Warm = they wrote back. Phase F: derive from a contact replying (the A3 lead rollup is
            // gone); the legacy lead outcome is kept as a fallback for un-backfilled stores.
            if p.outcome == .replied || p.recipients.contains(where: \.replied) {
                return HistoryRecord(groupName: p.groupName, status: "warm")
            }
            if p.sentAt != nil {
                return HistoryRecord(groupName: p.groupName, status: "contacted")
            }
            return nil
        }
    }

    // The one-time legacy booking-history import (group name + status), produced by
    // scripts/import-history.ts (pnpm import-history) from Dan's booking CSV. Absent file = no
    // history yet, which is normal, not an error.
    static var importedURL: URL {
        StoreLocation.handoffDirectory.appendingPathComponent("overture-history.json")
    }

    static func imported(from url: URL = importedURL) -> [HistoryRecord] {
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode([HistoryRecord].self, from: data) else { return [] }
        return history
    }

    // The COMPLETE history any matcher should see: the legacy import plus Overture's own activity.
    // Shared (#751) so the scout and Prep match against the same records. They used to compose this
    // separately, which would have let the same performer read as a past client in one place and a
    // stranger in the other, with nothing catching the discrepancy.
    static func forMatching(existing: [Prospect], importedFrom url: URL = importedURL) -> [HistoryRecord] {
        imported(from: url) + records(from: existing)
    }
}
