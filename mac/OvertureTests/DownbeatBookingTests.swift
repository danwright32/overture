import Testing
import Foundation
import SwiftData

// #41 / #99: Auto-books only on exact per-event proof (booking date in range, causally
// valid). The old client-list org match is downgraded to a suggestion. All guards:
// health gate, manual-outcome sticky, monotonic, 1:1 booking-to-prospect.
@MainActor
@Suite("Downbeat auto-booked")
struct DownbeatBookingTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func make(_ ctx: ModelContext, group: String, status: ReviewStatus,
                      outcome: Outcome = .noResponse, source: OutcomeSource? = nil,
                      sentAt: Date? = nil, performanceDate: String? = "2026-07-01",
                      clientId: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "choral", venue: "V",
                         performanceDate: performanceDate, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        p.outcome = outcome
        p.outcomeSourceRaw = source?.rawValue
        p.sentAt = sentAt
        // #963: a real send always stamps gmailMessageId alongside sentAt, so the fixture must too,
        // or a "sent" prospect here would no longer count once reconcileBooked reads
        // wasProvablyContacted instead of the bare timestamp.
        if sentAt != nil { p.gmailMessageId = "msg-\(group)" }
        p.downbeatClientId = clientId
        ctx.insert(p)
        return p
    }

    private func client(_ name: String, id: String = "C1") -> DownbeatClient {
        DownbeatClient(id: id, displayName: name, shortName: nil, email: "a@x.org",
                       contractEmail: "a@x.org", phoneNumber: nil, isTaxExempt: nil, hasLeftReview: false,
                       specialBehaviors: [], notes: nil, hostingSite: "x.org")
    }

    private func booking(id: String = "B1", clientId: String = "C1",
                         start: String = "2026-07-01", end: String = "2026-07-01") -> OvertureBooking {
        OvertureBooking(id: id, clientId: clientId, clientDisplayName: "Acme Festival Chorus",
                        shootName: "Gala", startDate: start, endDate: end, venueId: nil, venueName: "V")
    }

    // ── OLD TESTS (adapted to new behavior) ──────────────────────────────────────

    // Old: client-list match → auto-book. New: client-list match → bookingSuggested only.
    @Test func contactedMatchBecomesBookedAuto() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved,
                     sentAt: Date(timeIntervalSince1970: 1_000))
        let now = Date(timeIntervalSince1970: 5_000)
        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [client("Acme Festival Chorus")],
                                                    bookings: [], health: .ok, now: now)
        #expect(count == 0)
        #expect(p.outcome == .noResponse)
        #expect(p.bookingSuggested == true)
    }

    @Test func alreadyAClientWhenPitchedIsNotReBooked() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved,
                     sentAt: Date(timeIntervalSince1970: 1_000))
        p.priorRelationshipAtSend = "booked"
        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [client("Acme Festival Chorus")],
                                                    bookings: [], health: .ok, now: Date())
        #expect(count == 0)
        #expect(p.outcome == .noResponse)
    }

    @Test func coldWhenPitchedThatBecomesAClientIsBooked() throws {
        // #66: cold at contact, now a Downbeat client. Old: auto-book. New: suggest only.
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved,
                     sentAt: Date(timeIntervalSince1970: 1_000))
        p.priorRelationshipAtSend = "none"
        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [client("Acme Festival Chorus")],
                                                    bookings: [], health: .ok, now: Date())
        #expect(count == 0)
        #expect(p.bookingSuggested == true)
    }

    @Test func uncontactedMatchIsLeftAlone() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Acme Festival Chorus", status: .queued)
        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [client("Acme Festival Chorus")],
                                                    bookings: [], health: .ok, now: Date())
        #expect(count == 0)
        #expect(p.outcome == .noResponse)
    }

    @Test func manualOutcomeIsNeverOverwritten() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved, outcome: .lostSoft, source: .manual)
        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [client("Acme Festival Chorus")],
                                                    bookings: [], health: .ok, now: Date())
        #expect(count == 0)
        #expect(p.outcome == .lostSoft)
    }

    @Test func noClientMatchLeavesItAlone() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Unrelated Ensemble", status: .approved)
        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [client("Acme Festival Chorus")],
                                                    bookings: [], health: .ok, now: Date())
        #expect(count == 0)
        #expect(p.outcome == .noResponse)
        #expect(p.bookingSuggested == false)
    }

    // ── NEW TESTS (7 behaviors, TDD) ─────────────────────────────────────────────

    // #418 A4 — a confirmed booking pauses every still-unsent recipient (booking-freeze), but leaves
    // an already-sent recipient alone. This is the freeze the locked model assumed but didn't exist.
    @Test func bookingSuppressesStillPendingRecipients() throws {
        let ctx = ModelContext(try container())
        let sendDay = Date(timeIntervalSince1970: 1_751_328_000 - 30 * 86_400)
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved,
                     sentAt: sendDay, performanceDate: "2026-07-01", clientId: "C1")
        let sent = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        sent.sendState = .sent; sent.sentAt = sendDay
        let pending = Recipient(id: "b@present.example", email: "b@present.example", provenance: .presenter)
        // pending by default
        p.setRecipients([sent, pending])
        let b = booking(id: "B99", clientId: "C1", start: "2026-07-01", end: "2026-07-01")

        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [], bookings: [b],
                                                    health: .ok, now: Date(timeIntervalSince1970: 9_999))
        #expect(count == 1)
        #expect(p.recipients.first { $0.id == "b@present.example" }?.sendState == .suppressed)
        #expect(p.recipients.first { $0.id == "b@present.example" }?.suppressionReason == .bookedElsewhere)
        #expect(p.recipients.first { $0.id == "a@act.example" }?.sendState == .sent)
    }

    // #963: a sent timestamp alone is not proof of a real send (#378's lesson, extended past the
    // Reached-out queue). A staged/corrupt record with only sentAt (no gmailMessageId) must never
    // auto-book, or a future bug that sets sentAt without sending could falsely mark a show booked.
    @Test func aSentTimestampWithoutAGmailMessageIdIsNeverAutoBooked() throws {
        let ctx = ModelContext(try container())
        let sendDay = Date(timeIntervalSince1970: 1_751_328_000 - 30 * 86_400)
        let p = Prospect(naturalKey: "Acme Festival Chorus", groupName: "Acme Festival Chorus",
                         discipline: "choral", venue: "V", performanceDate: "2026-07-01",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .approved)
        p.sentAt = sendDay   // no gmailMessageId: never actually sent
        p.downbeatClientId = "C1"
        ctx.insert(p)
        let b = booking(id: "B99", clientId: "C1", start: "2026-07-01", end: "2026-07-01")

        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [], bookings: [b],
                                                    health: .ok, now: Date(timeIntervalSince1970: 9_999))

        #expect(count == 0)
        #expect(p.outcome != .booked)
    }

    // 1. Exact match auto-books a contacted, sent prospect.
    @Test func exactMatchAutoBooks() throws {
        let ctx = ModelContext(try container())
        let sendDay = Date(timeIntervalSince1970: 1_751_328_000 - 30 * 86_400)
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved,
                     sentAt: sendDay, performanceDate: "2026-07-01", clientId: "C1")
        let b = booking(id: "B99", clientId: "C1", start: "2026-07-01", end: "2026-07-01")
        let now = Date(timeIntervalSince1970: 9_999)
        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [], bookings: [b],
                                                    health: .ok, now: now)
        #expect(count == 1)
        #expect(p.outcome == .booked)
        #expect(p.outcomeSourceRaw == OutcomeSource.auto.rawValue)
        #expect(p.outcomeAt == now)
        #expect(p.bookingSuggested == false)
        // #203: the booking that auto-booked is recorded so Dan can later reject that exact one.
        #expect(p.autoBookedFromBookingId == "B99")
    }

    // 2. Possible (booking predates send) → bookingSuggested, not booked.
    @Test func possibleSetsSuggested() throws {
        let ctx = ModelContext(try container())
        let bookingStart = Date(timeIntervalSince1970: 1_751_328_000)
        let sentAfter = bookingStart.addingTimeInterval(5 * 86_400)
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved,
                     sentAt: sentAfter, performanceDate: "2026-07-01", clientId: "C1")
        let startStr = BookingMatch.dayString(from: bookingStart)
        let b = OvertureBooking(id: "B-poss", clientId: "C1", clientDisplayName: "Acme Festival Chorus",
                                shootName: "", startDate: startStr, endDate: "2026-07-01", venueId: nil, venueName: "V")
        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [], bookings: [b],
                                                    health: .ok, now: Date())
        #expect(count == 0)
        #expect(p.outcome == .noResponse)
        #expect(p.bookingSuggested == true)
    }

    // 3. None match but org in client list → bookingSuggested, not booked.
    @Test func noneWithClientListSetsSuggested() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved,
                     sentAt: Date(timeIntervalSince1970: 1_000))
        let count = DownbeatBooking.reconcileBooked(
            prospects: [p], clients: [client("Acme Festival Chorus")],
            bookings: [], health: .ok, now: Date())
        #expect(count == 0)
        #expect(p.bookingSuggested == true)
        #expect(p.outcome == .noResponse)
    }

    // 4. Unhealthy export → nothing changes, returns 0.
    @Test func unhealthyExportDoesNothing() throws {
        let ctx = ModelContext(try container())
        let sendDay = Date(timeIntervalSince1970: 1_751_328_000 - 30 * 86_400)
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved,
                     sentAt: sendDay, performanceDate: "2026-07-01", clientId: "C1")
        let b = booking(id: "B-health", clientId: "C1", start: "2026-07-01", end: "2026-07-01")
        for health: DownbeatBridge.Health in [.stale(ageDays: 31), .missing, .unreadable] {
            let count = DownbeatBooking.reconcileBooked(
                prospects: [p], clients: [client("Acme Festival Chorus")],
                bookings: [b], health: health, now: Date())
            #expect(count == 0, "health \(health) should return 0")
            #expect(p.outcome == .noResponse, "health \(health) should not change outcome")
            #expect(p.bookingSuggested == false, "health \(health) should not set suggestion")
        }
    }

    // 5. Already-booked prospect stays booked (monotonic).
    @Test func alreadyBookedProspectIsUntouched() throws {
        let ctx = ModelContext(try container())
        let sendDay = Date(timeIntervalSince1970: 1_751_328_000 - 30 * 86_400)
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved,
                     outcome: .booked, source: .auto,
                     sentAt: sendDay, performanceDate: "2026-07-01", clientId: "C1")
        let b = booking(clientId: "C1", start: "2026-07-01", end: "2026-07-01")
        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [],
                                                    bookings: [b], health: .ok, now: Date())
        #expect(count == 0)
        #expect(p.outcome == .booked)
    }

    // 6. Manual outcome is left untouched.
    @Test func manualOutcomeUntouchedByNewReconcile() throws {
        let ctx = ModelContext(try container())
        let sendDay = Date(timeIntervalSince1970: 1_751_328_000 - 30 * 86_400)
        let p = make(ctx, group: "Acme Festival Chorus-manual", status: .approved,
                     outcome: .lostSoft, source: .manual,
                     sentAt: sendDay, performanceDate: "2026-07-01", clientId: "C1")
        let b = booking(clientId: "C1", start: "2026-07-01", end: "2026-07-01")
        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [],
                                                    bookings: [b], health: .ok, now: Date())
        #expect(count == 0)
        #expect(p.outcome == .lostSoft)
    }

    // 7. Two prospects matching the same booking: exactly one books, other gets suggestion.
    @Test func oneBookingOneProspect() throws {
        let ctx = ModelContext(try container())
        let sendDay = Date(timeIntervalSince1970: 1_751_328_000 - 30 * 86_400)
        let b = booking(id: "B-shared", clientId: "C1", start: "2026-07-01", end: "2026-07-01")
        let p1 = Prospect(naturalKey: "p1-key", groupName: "Acme Festival Chorus", discipline: "choral",
                          venue: "V", performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: .approved)
        p1.sentAt = sendDay
        p1.gmailMessageId = "msg-p1"
        p1.downbeatClientId = "C1"
        let p2 = Prospect(naturalKey: "p2-key", groupName: "Acme Festival Chorus", discipline: "choral",
                          venue: "V", performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: .approved)
        p2.sentAt = sendDay
        p2.gmailMessageId = "msg-p2"
        p2.downbeatClientId = "C1"
        ctx.insert(p1)
        ctx.insert(p2)
        let count = DownbeatBooking.reconcileBooked(prospects: [p1, p2], clients: [],
                                                    bookings: [b], health: .ok, now: Date())
        #expect(count == 1)
        let bookedCount = [p1, p2].filter { $0.outcome == .booked }.count
        let suggestedCount = [p1, p2].filter { $0.bookingSuggested }.count
        #expect(bookedCount == 1)
        #expect(suggestedCount == 1)
    }

    // ── TASK 4 (revised): dismissal silences soft suggestions; exact booking still auto-books (#114) ──

    // 8. Dismissed prospect whose org IS in the client list: reconcile must not re-suggest.
    @Test func dismissedProspectIsNotReSuggested() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved,
                     sentAt: Date(timeIntervalSince1970: 1_000))
        p.bookingSuggestionDismissed = true
        let count = DownbeatBooking.reconcileBooked(
            prospects: [p], clients: [client("Acme Festival Chorus")],
            bookings: [], health: .ok, now: Date())
        #expect(count == 0)
        #expect(p.bookingSuggested == false)
        #expect(p.outcome == .noResponse)
    }

    // 9. Dismissed prospect with a .possible (causation-failed) booking: must not re-suggest.
    @Test func dismissedProspectWithPossibleIsNotReSuggested() throws {
        let ctx = ModelContext(try container())
        let bookingStart = Date(timeIntervalSince1970: 1_751_328_000)
        let sentAfter = bookingStart.addingTimeInterval(5 * 86_400)
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved,
                     sentAt: sentAfter, performanceDate: "2026-07-01", clientId: "C1")
        p.bookingSuggestionDismissed = true
        let startStr = BookingMatch.dayString(from: bookingStart)
        let b = OvertureBooking(id: "B-poss-dismissed", clientId: "C1",
                                clientDisplayName: "Acme Festival Chorus",
                                shootName: "", startDate: startStr, endDate: "2026-07-01",
                                venueId: nil, venueName: "V")
        let count = DownbeatBooking.reconcileBooked(
            prospects: [p], clients: [], bookings: [b], health: .ok, now: Date())
        #expect(count == 0)
        #expect(p.bookingSuggested == false)
        #expect(p.outcome == .noResponse)
    }

    // 10. Dismissed prospect with an EXACT matching booking: hard proof wins, must still auto-book.
    @Test func dismissedProspectWithExactMatchIsAutoBooked() throws {
        let ctx = ModelContext(try container())
        let sendDay = Date(timeIntervalSince1970: 1_751_328_000 - 30 * 86_400)
        let now = Date(timeIntervalSince1970: 9_999_999)
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved,
                     sentAt: sendDay, performanceDate: "2026-07-01", clientId: "C1")
        p.bookingSuggestionDismissed = true
        let b = booking(id: "B-dismissed-exact", clientId: "C1", start: "2026-07-01", end: "2026-07-01")
        let count = DownbeatBooking.reconcileBooked(
            prospects: [p], clients: [], bookings: [b], health: .ok, now: now)
        #expect(count == 1)
        #expect(p.outcome == .booked)
        #expect(p.outcomeSourceRaw == OutcomeSource.auto.rawValue)
        #expect(p.bookingSuggested == false)
    }

    // 11. Sanity: a non-dismissed prospect still gets suggested/booked as before.
    @Test func nonDismissedProspectStillAutoBooks() throws {
        let ctx = ModelContext(try container())
        let sendDay = Date(timeIntervalSince1970: 1_751_328_000 - 30 * 86_400)
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved,
                     sentAt: sendDay, performanceDate: "2026-07-01", clientId: "C1")
        p.bookingSuggestionDismissed = false
        let b = booking(id: "B-sanity", clientId: "C1", start: "2026-07-01", end: "2026-07-01")
        let count = DownbeatBooking.reconcileBooked(
            prospects: [p], clients: [], bookings: [b], health: .ok, now: Date())
        #expect(count == 1)
        #expect(p.outcome == .booked)
    }

    // ── #203: reject a wrong auto-detected booking (per-booking suppression) ──────

    // Rejecting reverts the auto-booked outcome and records the rejected booking id.
    @Test func rejectAutoBookingRevertsAndRecords() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved,
                     outcome: .booked, source: .auto)
        p.autoBookedFromBookingId = "B99"
        p.rejectAutoBooking(bookingId: "B99", now: Date(timeIntervalSince1970: 7_000))
        #expect(p.outcome == .noResponse)
        #expect(p.outcomeSourceRaw == nil)
        #expect(p.rejectedBookingIds.contains("B99"))
    }

    // A rejected booking id is never re-booked, even on an otherwise-exact match.
    @Test func rejectedBookingIsNotReBooked() throws {
        let ctx = ModelContext(try container())
        let sendDay = Date(timeIntervalSince1970: 1_751_328_000 - 30 * 86_400)
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved,
                     sentAt: sendDay, performanceDate: "2026-07-01", clientId: "C1")
        p.rejectAutoBooking(bookingId: "B99", now: Date(timeIntervalSince1970: 7_000))
        let b = booking(id: "B99", clientId: "C1", start: "2026-07-01", end: "2026-07-01")
        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [], bookings: [b],
                                                    health: .ok, now: Date())
        #expect(count == 0)
        #expect(p.outcome == .noResponse)
        #expect(p.bookingSuggested == false)
    }

    // Rejecting one booking does not stop a DIFFERENT genuine booking from auto-detecting.
    @Test func rejectingOneBookingStillAllowsAnother() throws {
        let ctx = ModelContext(try container())
        let sendDay = Date(timeIntervalSince1970: 1_751_328_000 - 30 * 86_400)
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved,
                     sentAt: sendDay, performanceDate: "2026-07-01", clientId: "C1")
        p.rejectAutoBooking(bookingId: "B-wrong", now: Date(timeIntervalSince1970: 7_000))
        let b = booking(id: "B-right", clientId: "C1", start: "2026-07-01", end: "2026-07-01")
        let now = Date(timeIntervalSince1970: 9_999)
        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [], bookings: [b],
                                                    health: .ok, now: now)
        #expect(count == 1)
        #expect(p.outcome == .booked)
        #expect(p.outcomeSourceRaw == OutcomeSource.auto.rawValue)
        #expect(p.autoBookedFromBookingId == "B-right")
    }

    // #218: a booking auto-detected before #203 has no recorded id (autoBookedFromBookingId nil).
    // Rejecting it must still stop reconcile from re-booking, via a per-prospect fallback.
    @Test func rejectingLegacyAutoBookingWithoutIdStillSuppresses() throws {
        let ctx = ModelContext(try container())
        let sendDay = Date(timeIntervalSince1970: 1_751_328_000 - 30 * 86_400)
        let p = make(ctx, group: "Acme Festival Chorus", status: .approved,
                     outcome: .booked, source: .auto,
                     sentAt: sendDay, performanceDate: "2026-07-01", clientId: "C1")
        p.autoBookedFromBookingId = nil
        p.rejectAutoBooking(bookingId: p.autoBookedFromBookingId, now: Date(timeIntervalSince1970: 7_000))
        let b = booking(id: "B-legacy", clientId: "C1", start: "2026-07-01", end: "2026-07-01")
        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [], bookings: [b],
                                                    health: .ok, now: Date())
        #expect(count == 0)
        #expect(p.outcome == .noResponse)
    }
}
