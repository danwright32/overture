import Testing
import Foundation
import SwiftData

// #2223, #2225, #2226. Three faults found on 2026-08-06 while working out what would happen to the first
// show that actually booked. None had ever been exercised, because no booking had ever completed the
// loop: they were unproven rather than known good.
//
// They are one shape. A booking is a fact that can sit at either of two levels, the show or one of its
// contacts, and each writer and reader picked a level on its own (L83). Auto-detection writes the show;
// the Mark… menu, which is the only way Dan can record a booking by hand, writes the contact. The
// reached-out queue read the contact and kept a booked show counting down to a nudge; the outcome report
// read the show and counted every hand-recorded booking as a reply.
@MainActor
@Suite("A booking reaches everything that has to know (#2223, #2225, #2226)")
struct ABookingReachesEverythingTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
    private var sendDay: String { "2023-11-14" }   // the day `sentAt` falls on, Eastern

    @discardableResult
    private func show(_ ctx: ModelContext, group: String = "Every Voice Choirs",
                      performanceDate: String = "2026-10-25",
                      priorRelationship: String = "none",
                      clientId: String? = "C698D5AB") -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "choral",
                         venue: "Sakura Park", performanceDate: performanceDate,
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: priorRelationship,
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .approved)
        p.priorRelationshipAtSend = priorRelationship
        p.downbeatClientId = clientId
        p.sentAt = sentAt
        p.gmailMessageId = "msg"
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func emailedContact(_ p: Prospect, _ address: String = "chelsea@everyvoicechoirs.org",
                                replied: Bool = false) -> Recipient {
        let r = Recipient(id: address, email: address, provenance: .presenter)
        r.sendState = .sent
        r.sentAt = sentAt
        r.gmailMessageId = "msg-\(address)"
        r.gmailThreadId = "t"
        if replied {
            r.replied = true
            r.repliedAt = sentAt.addingTimeInterval(86_400)
        }
        p.addRecipient(r)
        return r
    }

    private func booking(id: String = "B1", clientId: String = "C698D5AB",
                         start: String, end: String? = nil) -> OvertureBooking {
        OvertureBooking(id: id, clientId: clientId, clientDisplayName: "Every Voice Choirs",
                        shootName: "Pumpkin Singalong", startDate: start, endDate: end ?? start,
                        venueId: nil, venueName: "Sakura Park")
    }

    private func client(_ id: String = "C698D5AB") -> DownbeatClient {
        DownbeatClient(id: id, displayName: "Every Voice Choirs", shortName: nil,
                       email: "a@everyvoicechoirs.org", contractEmail: "a@everyvoicechoirs.org",
                       phoneNumber: nil, isTaxExempt: nil, hasLeftReview: false,
                       specialBehaviors: [], notes: nil, hostingSite: "everyvoicechoirs.org")
    }

    // MARK: - #2223: an organisation Dan has worked with before

    // The measured case: Prospect 645, Every Voice Choirs, pitched to an org already in the client list,
    // matched on the client id. Every other guard passed. This is the segment most likely to book, so it
    // is exactly the conversion the feature exists to measure.
    @Test func ashowPitchedToAPastClientStillAutoBooks() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, priorRelationship: "booked")
        emailedContact(p)

        let count = DownbeatBooking.reconcileBooked(
            prospects: [p], clients: [client()],
            bookings: [booking(start: "2026-10-25")], health: .ok, now: Date())

        #expect(count == 1)
        #expect(p.outcome == .booked)
    }

    // And a booking that genuinely predates the pitch still does not, because that causation is enforced
    // per booking rather than per organisation.
    @Test func abookingThatPredatesThePitchStillDoesNotAutoBook() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, performanceDate: "2023-11-01", priorRelationship: "booked")
        emailedContact(p)

        let count = DownbeatBooking.reconcileBooked(
            prospects: [p], clients: [client()],
            bookings: [booking(start: "2023-11-01")], health: .ok, now: Date())

        #expect(count == 0)
        #expect(p.outcome == .noResponse)
        #expect(p.bookingSuggested, "a soft signal is still offered, so it is never silence")
    }

    // A past client with NO matching booking raises nothing. All the client-list fallback could say is
    // "this organisation is in the client list", which is the thing the row already records, and it would
    // fire on every past-client pitch forever.
    @Test func apastClientWithNoMatchingBookingIsNotSuggested() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, priorRelationship: "booked")
        emailedContact(p)

        let count = DownbeatBooking.reconcileBooked(prospects: [p], clients: [client()],
                                                    bookings: [], health: .ok, now: Date())

        #expect(count == 0)
        #expect(!p.bookingSuggested)
    }

    // While a COLD show with no matching booking keeps the fallback it has always had.
    @Test func acoldShowKeepsTheClientListFallback() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, priorRelationship: "none")
        emailedContact(p)

        _ = DownbeatBooking.reconcileBooked(prospects: [p], clients: [client()],
                                            bookings: [], health: .ok, now: Date())

        #expect(p.bookingSuggested)
    }

    // MARK: - #2225: the row leaves Reached out

    @Test func abookingRecordedOnAContactTakesItsRowOutOfReachedOut() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedContact(p, replied: true)
        let now = sentAt.addingTimeInterval(10 * 86_400)
        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: now) != nil,
                "the premise: this row is in Reached out before anything books")

        r.markOutcomeManually(resolution: .booked, bounced: false)

        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: now) == nil)
        #expect(ReachedOutQueue.active(from: [p], now: now).isEmpty)
    }

    // The case the existing coverage misses entirely: a colleague who was already emailed and whose own
    // resolution nobody ever touches. Both booking paths freeze only the contacts that were never sent to.
    @Test func analreadyEmailedColleagueLeavesToo() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let booked = emailedContact(p, "chelsea@everyvoicechoirs.org", replied: true)
        let colleague = emailedContact(p, "office@everyvoicechoirs.org")
        let now = sentAt.addingTimeInterval(10 * 86_400)
        #expect(ReachedOutQueue.nextReachOut(for: colleague, of: p, now: now) != nil)

        booked.markOutcomeManually(resolution: .booked, bounced: false)

        #expect(colleague.resolution == nil, "nothing froze this contact; the SHOW booking is what speaks")
        #expect(ReachedOutQueue.nextReachOut(for: colleague, of: p, now: now) == nil)
    }

    // An auto-detected booking, which writes the show rather than a contact, does the same.
    @Test func anautoDetectedBookingAlsoEmptiesTheRow() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedContact(p, replied: true)
        let now = sentAt.addingTimeInterval(10 * 86_400)

        p.markAutoBooked(bookingId: "B1", now: now)

        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: now) == nil)
    }

    // The failure path, so the fix cannot be a blanket exclusion: a show that is NOT booked, with exactly
    // the same contact shape, still appears.
    @Test func ashowThatHasNotBookedStaysInReachedOut() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedContact(p, replied: true)
        let now = sentAt.addingTimeInterval(10 * 86_400)

        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: now) != nil)
        #expect(ReachedOutQueue.active(from: [p], now: now).count == 1)
    }

    // MARK: - #2226: the report counts it

    @Test func abookingRecordedOnAContactCountsAsBooked() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedContact(p, replied: true)
        r.markOutcomeManually(resolution: .booked, bounced: false)

        let tally = OutcomeStats.tally(OutcomePatterns.samples(from: [p], by: .production))

        #expect(tally.booked == 1)
        #expect(tally.replied == 0, "a booking is not a reply, whichever level it was written at")
        #expect(tally.bookedManual == 1, "Dan recorded it, so it is his call, not a detection")
        #expect(tally.bookedAuto == 0)
    }

    @Test func anautoDetectedBookingIsStillAttributedToDetection() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        emailedContact(p, replied: true)
        p.markAutoBooked(bookingId: "B1", now: Date())

        let tally = OutcomeStats.tally(OutcomePatterns.samples(from: [p], by: .production))

        #expect(tally.booked == 1)
        #expect(tally.bookedAuto == 1)
        #expect(tally.bookedManual == 0)
    }

    // The failure path: the fix must not turn every reply into a booking.
    @Test func areplyWithNoBookingIsStillJustAReply() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        emailedContact(p, replied: true)

        let tally = OutcomeStats.tally(OutcomePatterns.samples(from: [p], by: .production))

        #expect(tally.replied == 1)
        #expect(tally.booked == 0)
    }

    // The auto and manual halves have to keep summing to the total they split, or the number the split
    // exists to keep honest goes quietly wrong.
    @Test func thebookedSplitStillSumsToTheTotal() throws {
        let ctx = ModelContext(try container())
        let byHand = show(ctx, group: "Every Voice Choirs")
        emailedContact(byHand).markOutcomeManually(resolution: .booked, bounced: false)
        let detected = show(ctx, group: "Aurora Strings", clientId: "C2")
        emailedContact(detected, "office@aurora.example")
        detected.markAutoBooked(bookingId: "B2", now: Date())

        let tally = OutcomeStats.tally(OutcomePatterns.samples(from: [byHand, detected], by: .production))

        #expect(tally.booked == 2)
        #expect(tally.bookedAuto + tally.bookedManual == tally.booked)
    }
}
