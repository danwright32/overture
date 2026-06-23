import Foundation

// Keeps repeat-client recognition current without a stale CSV re-import (#19). The
// matching history is derived live from Overture's own activity: an org it has emailed
// is "contacted", a booked outcome is "booked". Merged with Downbeat (canonical booked,
// passed separately) and any one-time legacy import, so every send Dan makes feeds the
// next scout's prior-relationship signal automatically.
enum LocalHistory {
    static func records(from prospects: [Prospect]) -> [HistoryRecord] {
        prospects.compactMap { p in
            if p.outcome == .booked {
                return HistoryRecord(groupName: p.groupName, status: "booked")
            }
            if p.sentAt != nil {
                return HistoryRecord(groupName: p.groupName, status: "contacted")
            }
            return nil
        }
    }
}
