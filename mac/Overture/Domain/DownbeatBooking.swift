import Foundation

// Auto-marks outcome from the canonical booking record (#41, #99). Uses per-event
// booking dates when available (exact match = auto-book), falls back to org-level
// client-list match as a suggestion for Dan to confirm. All guards are in place:
// health gate, manual-outcome sticky, monotonic (never reverts a booking), 1:1
// booking-to-prospect via consumed-id set.
enum DownbeatBooking {
    @discardableResult
    static func reconcileBooked(
        prospects: [Prospect],
        clients: [DownbeatClient],
        bookings: [OvertureBooking],
        health: DownbeatBridge.Health,
        now: Date
    ) -> Int {
        guard health == .ok else { return 0 }
        var count = 0
        var consumed: Set<String> = []
        // Deterministic order: sort by performanceDate then groupName so 1:1 booking
        // consumption is stable across runs.
        let sorted = prospects
            .filter { $0.wasContacted }
            .sorted {
                let d0 = $0.performanceDate ?? ""
                let d1 = $1.performanceDate ?? ""
                if d0 != d1 { return d0 < d1 }
                return $0.groupName < $1.groupName
            }
        for p in sorted {
            if p.outcomeSourceRaw == OutcomeSource.manual.rawValue { continue }
            if p.outcome == .booked { continue }
            if p.priorRelationshipAtSend == PriorRelationship.booked.rawValue { continue }
            switch BookingMatch.classify(prospect: p, bookings: bookings) {
            case .exact(let booking):
                // Dan rejected this exact booking as a wrong match (#203), or rejected a legacy
                // auto-booking with no recorded id (#218): never re-book from it, and don't fall
                // through to suggesting it either.
                if p.autoBookingRejectedWithoutId || p.rejectedBookingIds.contains(booking.id) { continue }
                if !consumed.contains(booking.id) {
                    p.outcome = .booked
                    p.outcomeSourceRaw = OutcomeSource.auto.rawValue
                    p.outcomeAt = now
                    p.bookingSuggested = false
                    p.autoBookedFromBookingId = booking.id
                    consumed.insert(booking.id)
                    count += 1
                } else {
                    // Tiebreak loser: suggest only if the prospect hasn't dismissed
                    if !p.bookingSuggestionDismissed { p.bookingSuggested = true }
                }
            case .possible:
                // Soft signal: don't re-suggest if dismissed
                if !p.bookingSuggestionDismissed { p.bookingSuggested = true }
            case .none:
                // Fall back to old client-list org match — downgraded to suggestion
                let orgMatch = clients.contains { client in
                    GroupNameMatch.isConfident(client.displayName, p.groupName)
                        || (client.shortName.map { GroupNameMatch.isConfident($0, p.groupName) } ?? false)
                }
                if orgMatch && !p.bookingSuggestionDismissed { p.bookingSuggested = true }
            }
        }
        return count
    }
}
