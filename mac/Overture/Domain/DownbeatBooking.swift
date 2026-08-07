import Foundation
import SwiftData

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
    // #1960: the two fetches and the boxing, named once and passed as an expression the health guard can
    // decline to evaluate. It was spelled out identically at both call sites, which is also how one of
    // them would have kept paying after the other stopped.
    // `prospects` is passed by a caller that has already fetched them for something else, so nothing is
    // fetched twice; a caller with none in hand omits it. `try?` yields none on a container predating
    // Inquiry.
    static func bookingEntities(prospects: [Prospect]? = nil,
                                in context: ModelContext) -> [any BookingMatchable] {
        let rows = prospects ?? (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let inquiries = (try? context.fetch(FetchDescriptor<Inquiry>())) ?? []
        return rows.map { $0 as any BookingMatchable } + inquiries.map { $0 as any BookingMatchable }
    }

    // #1960: `entities` is an @autoclosure because the health guard below refuses without touching them,
    // and an argument is evaluated BEFORE the call. Both call sites fetch every prospect AND every
    // inquiry and box each one, so a Mac with no Downbeat export was sweeping the whole store on every
    // reconcile tick and every scout to reach a line that returns zero.
    @discardableResult
    static func reconcileBooked(
        entities: @autoclosure () -> [any BookingMatchable],
        clients: [DownbeatClient],
        bookings: [OvertureBooking],
        health: DownbeatBridge.Health,
        now: Date
    ) -> Int {
        guard health == .ok else { return 0 }
        let entities = entities()
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
                // #1434 tie-break: at the same date a suggestion-only entity (an Inquiry) is reached
                // BEFORE an auto-booking one (a Prospect), so it claims a shared booking first and the
                // prospect is downgraded to a suggestion rather than auto-booking. Among same-kind
                // entities this is constant and falls through to the stable groupName order.
                if $0.permitsAutoBook != $1.permitsAutoBook { return !$0.permitsAutoBook }
                return $0.groupName < $1.groupName
            }
        for p in sorted {
            if p.bookingManualOutcome { continue }
            if p.bookingIsBooked { continue }
            // #2223: an organisation that was ALREADY a client when this went out used to be skipped here,
            // before `classify` was ever called. That conflated two different facts: "this organisation
            // was already a client" and "this booking is not new". A booking for THIS show's date, created
            // after the pitch went out, is a new booking whatever the history.
            //
            // The causation the skip was reaching for is enforced one level down, per booking:
            // `BookingMatch.classify` requires `booking.startDate >= sendDay` for an exact match and
            // demotes anything earlier to `.possible`. So it was redundant against a real booking and
            // total against everything else, which closed the loop off for the segment most likely to
            // book. Measured 2026-08-06 on the first show that actually booked (Prospect 645, Every Voice
            // Choirs, matched on the client id): every other guard would have passed.
            //
            // What it WAS doing usefully is suppressed where it belongs, in the `.none` branch below.
            switch BookingMatch.classify(entity: p, bookings: bookings) {
            case .exact(let booking):
                // Dan rejected this exact booking as a wrong match (#203), or rejected a legacy
                // auto-booking with no recorded id (#218): never re-book from it, and don't fall
                // through to suggesting it either.
                if p.autoBookingRejectedWithoutId || p.rejectedBookingIds.contains(booking.id) { continue }
                if !consumed.contains(booking.id) {
                    // Claim the booking either way so it is consumed once across the whole list (the
                    // #1434 dual-attribution guarantee). A prospect auto-books; a suggestion-only entity
                    // (an Inquiry) only suggests, but its claim still blocks a competing prospect from
                    // auto-booking the same booking (#1435 suggestion-only, #1434 tie-break).
                    consumed.insert(booking.id)
                    if p.permitsAutoBook {
                        // The confirmed auto-book (outcome, source, timestamp, id, booking-freeze) is the
                        // conformer's own `markAutoBooked` so each entity applies its own freeze semantics.
                        p.markAutoBooked(bookingId: booking.id, now: now)
                        count += 1
                    } else if !p.bookingSuggestionDismissed {
                        p.bookingSuggested = true
                    }
                } else {
                    // Tiebreak loser: suggest only if the entity hasn't dismissed
                    if !p.bookingSuggestionDismissed { p.bookingSuggested = true }
                }
            case .possible:
                // Soft signal: don't re-suggest if dismissed
                if !p.bookingSuggestionDismissed { p.bookingSuggested = true }
            case .none:
                // #2223: no booking matched, so all this fallback can say is "this organisation is in the
                // client list". On a show pitched to an org that was ALREADY a client that is not news, it
                // is the thing the row already records, and it would fire on every past-client pitch
                // forever. That noise is the real work the org-level skip above was doing, and this is
                // where it belongs: it suppresses a guess, not a matched booking.
                if p.bookingPriorRelationshipBooked { break }
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
