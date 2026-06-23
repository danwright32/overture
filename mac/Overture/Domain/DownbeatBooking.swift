import Foundation

// Auto-marks outcome from the canonical booking record (#41). Downbeat's client list is
// ground truth for who Dan has booked; when a prospect he actually contacted matches a
// Downbeat client, record the booking automatically so it isn't manual data entry.
//
// Scoped to CONTACTED prospects so repeat clients we never pitched aren't falsely booked,
// and manual outcomes are always left untouched. NOTE: the bridge currently exports only
// the client list (no per-booking dates), so this is an org-level signal Dan can correct;
// precise per-event booking detection waits on the bridge carrying booking dates.
enum DownbeatBooking {
    @discardableResult
    static func reconcileBooked(prospects: [Prospect], clients: [DownbeatClient], now: Date) -> Int {
        guard !clients.isEmpty else { return 0 }
        var count = 0
        for p in prospects where p.wasContacted {
            if p.outcomeSourceRaw == OutcomeSource.manual.rawValue { continue } // Dan's call is sticky
            if p.outcome == .booked { continue }                                 // already recorded
            let matches = clients.contains { client in
                GroupNameMatch.isConfident(client.displayName, p.groupName)
                    || (client.shortName.map { GroupNameMatch.isConfident($0, p.groupName) } ?? false)
            }
            if matches {
                p.outcome = .booked
                p.outcomeSourceRaw = OutcomeSource.auto.rawValue
                p.outcomeAt = now
                count += 1
            }
        }
        return count
    }
}
