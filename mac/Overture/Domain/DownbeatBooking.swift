import Foundation

// Auto-marks outcome from the canonical booking record (#41, #99). Uses per-event
// booking dates when available (exact match = auto-book), falls back to org-level
// client-list match as a suggestion for Dan to confirm. All guards are in place:
// health gate, manual-outcome sticky, monotonic (never reverts a booking), 1:1
// booking-to-prospect via consumed-id set.
enum DownbeatBooking {
    // Back-compat overload for the concrete `Prospect` callers/tests (#1434); forwards into the
    // genericized single-pass core below.
    @discardableResult
    static func reconcileBooked(
        prospects: [Prospect],
        clients: [DownbeatClient],
        bookings: [OvertureBooking],
        health: DownbeatBridge.Health,
        now: Date
    ) -> Int {
        reconcileBooked(entities: prospects, clients: clients, bookings: bookings, health: health, now: now)
    }

    // Genericized over `BookingMatchable` (#1434). One `consumed` set spans the WHOLE entity list, so
    // a single real booking is auto-booked exactly once even when a Prospect and an Inquiry both match
    // it (the dual-attribution bug this closes): the first in deterministic order wins the booking, the
    // rest fall to a suggestion.
    @discardableResult
    static func reconcileBooked(
        entities: [any BookingMatchable],
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
        let sorted = entities
            .filter { $0.wasProvablyContacted }
            .sorted {
                let d0 = $0.performanceDate ?? ""
                let d1 = $1.performanceDate ?? ""
                if d0 != d1 { return d0 < d1 }
                return $0.groupName < $1.groupName
            }
        for p in sorted {
            if p.bookingManualOutcome { continue }
            if p.bookingIsBooked { continue }
            if p.bookingPriorRelationshipBooked { continue }
            switch BookingMatch.classify(entity: p, bookings: bookings) {
            case .exact(let booking):
                // Dan rejected this exact booking as a wrong match (#203), or rejected a legacy
                // auto-booking with no recorded id (#218): never re-book from it, and don't fall
                // through to suggesting it either.
                if p.autoBookingRejectedWithoutId || p.rejectedBookingIds.contains(booking.id) { continue }
                if !consumed.contains(booking.id) {
                    // The confirmed auto-book (outcome, source, timestamp, id, booking-freeze) is the
                    // conformer's own `markAutoBooked` so each entity applies its own freeze semantics.
                    p.markAutoBooked(bookingId: booking.id, now: now)
                    consumed.insert(booking.id)
                    count += 1
                } else {
                    // Tiebreak loser: suggest only if the entity hasn't dismissed
                    if !p.bookingSuggestionDismissed { p.bookingSuggested = true }
                }
            case .possible:
                // Soft signal: don't re-suggest if dismissed
                if !p.bookingSuggestionDismissed { p.bookingSuggested = true }
            case .none:
                // Fall back to old client-list org match, downgraded to suggestion
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
