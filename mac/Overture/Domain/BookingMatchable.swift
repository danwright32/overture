import Foundation

// Phase 1 (#1434): the seam that lets Downbeat booking-match run over ANY bookable entity, not just
// `Prospect`, so an Inquiry (#1435) reconciles against the SAME booking export in the SAME single
// pass. Sharing one pass (one `consumed` set) is the point: two separate passes, one per entity
// type, could each auto-book the same real booking to a different entity and silently double-count
// the year-end conversion the feature exists to measure. Class-bound so `markAutoBooked` reaches the
// live `@Model`.
//
// Guards are semantic booleans, not raw enums, so a conformer with its own outcome model still
// expresses the same "don't touch" rules (manually resolved, already booked, booked-at-send).
protocol BookingMatchable: AnyObject {
    // Inputs BookingMatch.classify reads:
    var groupName: String { get }
    var venue: String? { get }
    var performanceDate: String? { get }
    var runEndDate: String? { get }
    var sentAt: Date? { get }
    var downbeatClientId: String? { get }

    // Guards reconcileBooked reads:
    var wasProvablyContacted: Bool { get }
    var bookingManualOutcome: Bool { get }          // Dan hand-set the outcome; sticky.
    var bookingIsBooked: Bool { get }                // already booked; monotonic, never revert.
    var bookingPriorRelationshipBooked: Bool { get } // already a client when pitched; not a new booking.
    var autoBookingRejectedWithoutId: Bool { get }   // Dan rejected a legacy auto-book with no id (#218).
    var rejectedBookingIds: Set<String> { get }      // specific booking ids Dan rejected (#203).
    var bookingSuggestionDismissed: Bool { get }
    var bookingSuggested: Bool { get set }

    // The confirmed auto-book: set outcome, stamp source/time, record the booking id, and freeze
    // the entity's still-unsent contacts. Encapsulated so each conformer applies its own freeze.
    func markAutoBooked(bookingId: String, now: Date)
}

extension Prospect: BookingMatchable {
    var bookingManualOutcome: Bool { outcomeSourceRaw == OutcomeSource.manual.rawValue }
    var bookingIsBooked: Bool { outcome == .booked }
    var bookingPriorRelationshipBooked: Bool { priorRelationshipAtSend == PriorRelationship.booked.rawValue }

    func markAutoBooked(bookingId: String, now: Date) {
        outcome = .booked
        outcomeSourceRaw = OutcomeSource.auto.rawValue
        outcomeAt = now
        bookingSuggested = false
        autoBookedFromBookingId = bookingId
        // Booking-freeze (#418 A4): a confirmed booking pauses every still-unsent recipient so
        // Overture stops emailing the other contacts on a show that already landed. Shared with the
        // manual booking/decline/closing paths (#542).
        suppressUntriedRecipients(reason: .bookedElsewhere)
    }
}
