import Testing
import Foundation
import SwiftData


// #2928: the one Gmail fixture builder, at file scope.
private let inquiryGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com")
// Phase 2 (#1435): the Inquiry record and its intake logic. An inquiry's identity is the EVENT
// (performance / date / venue), NOT the inquirer's email, because Dan logs it by hand and wouldn't
// re-log the same event twice. The duplicate check is SOFT (a warning, not a hard unique
// constraint), because venue and date can legitimately be unknown at intake.
@MainActor
@Suite("Inquiry natural key and soft duplicate check")
struct InquiryTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @Test func keyCanonicalizesEventDateVenue() {
        let a = Inquiry.makeNaturalKey(eventName: "Spring  Gala", performanceDate: "2026-05-01", venue: "Carnegie Hall")
        let b = Inquiry.makeNaturalKey(eventName: "spring gala", performanceDate: "2026-05-01", venue: "carnegie hall")
        #expect(a == b)
    }

    @Test func differentDatesProduceDifferentKeys() {
        let a = Inquiry.makeNaturalKey(eventName: "Gala", performanceDate: "2026-05-01", venue: "V")
        let b = Inquiry.makeNaturalKey(eventName: "Gala", performanceDate: "2026-06-01", venue: "V")
        #expect(a != b)
    }

    // The natural key is the EVENT, so two inquiries for the same show collide even with different
    // inquirer emails.
    @Test func sameEventFromTwoDifferentPeopleCollides() {
        let a = Inquiry.makeNaturalKey(eventName: "Gala", performanceDate: "2026-05-01", venue: "V")
        let b = Inquiry.makeNaturalKey(eventName: "Gala", performanceDate: "2026-05-01", venue: "V")
        #expect(a == b)
    }

    @Test func softDuplicateCheckFlagsAnExistingEventButDoesNotBlockInsert() throws {
        let ctx = ModelContext(try container())
        let first = Inquiry(source: .contactForm, inquirerName: "Ada", inquirerEmail: "ada@x.org",
                            eventName: "Gala", performanceDate: "2026-05-01", venue: "V")
        ctx.insert(first)
        let dupKey = Inquiry.makeNaturalKey(eventName: "gala", performanceDate: "2026-05-01", venue: "v")
        #expect(InquiryIntake.duplicate(ofKey: dupKey, in: [first]) === first)
        // A different event is not a duplicate.
        let freshKey = Inquiry.makeNaturalKey(eventName: "Recital", performanceDate: "2026-05-01", venue: "V")
        #expect(InquiryIntake.duplicate(ofKey: freshKey, in: [first]) == nil)
    }

    // An inquiry with no known venue or date must not falsely collide with another under-specified
    // one on a different event: a blank key is never treated as a duplicate.
    @Test func anEmptyEventDoesNotCollideWithAnotherEmptyOne() throws {
        let ctx = ModelContext(try container())
        let bare = Inquiry(source: .directEmail, inquirerName: "Someone", inquirerEmail: nil,
                           eventName: "", performanceDate: nil, venue: nil)
        ctx.insert(bare)
        let otherBareKey = Inquiry.makeNaturalKey(eventName: "", performanceDate: nil, venue: nil)
        #expect(InquiryIntake.duplicate(ofKey: otherBareKey, in: [bare]) == nil)
    }

    // Dan marks an inquiry booked or lost by hand (Lost is ALWAYS a manual close, #1435). A manual
    // mark is sticky: it stamps the manual source so auto reply/booking detection never overwrites it,
    // and it clears any booking suggestion.
    @Test func markingBookedIsAManualStickyOutcome() {
        let inq = Inquiry(source: .directEmail, inquirerName: "Ada", inquirerEmail: nil, eventName: "Gala")
        inq.bookingSuggested = true
        inq.markOutcomeManually(.booked, now: Date(timeIntervalSince1970: 5))
        #expect(inq.outcome == .booked)
        #expect(inq.outcomeSourceRaw == OutcomeSource.manual.rawValue)
        #expect(inq.outcomeAt == Date(timeIntervalSince1970: 5))
        #expect(inq.bookingSuggested == false)
        #expect(inq.isOpen == false)
    }

    @Test func markingLostClosesTheInquiry() {
        let inq = Inquiry(source: .contactForm, inquirerName: "Bo", inquirerEmail: nil, eventName: "Recital")
        inq.markOutcomeManually(.lostSoft, now: Date())
        #expect(inq.isOpen == false)
        #expect(inq.outcomeSourceRaw == OutcomeSource.manual.rawValue)
    }

    // Intake trims its inputs and turns blank optional fields into nil, so the form stays dumb and the
    // rules live here (the WatchlistEditing idiom). The built inquiry is inserted.
    @Test func createTrimsInputsNilsBlanksAndInserts() throws {
        let ctx = ModelContext(try container())
        let inq = InquiryIntake.create(source: .contactForm, name: "  Ada Lovelace  ",
                                       email: "   ", eventName: "  Gala  ", performanceDate: nil,
                                       venue: "   ", notes: "Wants a portrait", in: ctx)
        #expect(inq.inquirerName == "Ada Lovelace")
        #expect(inq.inquirerEmail == nil)
        #expect(inq.venue == nil)
        #expect(inq.notes == "Wants a portrait")
        #expect(inq.source == .contactForm)
        #expect(try ctx.fetch(FetchDescriptor<Inquiry>()).count == 1)
    }
}

// An inquiry has ONE email thread, not a contact list, so it rides the Phase 1 ReplyWatchable seam
// as its own single recipient. These prove reply and bounce detection reach an inquiry through the
// SAME ReplyService / BounceService code prospects use.
@MainActor
@Suite("Inquiry rides the shared reply/bounce pipeline")
struct InquiryReplyWatchableTests {
    private let me = "dan@danwrightphotography.com"
    private let replyThread = inquiryGmail.thread([.init(from: "dan@danwrightphotography.com"),
                                                   .init(from: "ada@x.org")])
    private func hardBounceJSON() -> Data {
        inquiryGmail.thread([
            .init(from: "mailer-daemon@googlemail.com",
                  subject: "Delivery Status Notification (Failure)", id: "bounce-1"),
        ])
    }

    private func sentInquiry(threadId: String = "t1") -> Inquiry {
        let inq = Inquiry(source: .directEmail, inquirerName: "Ada", inquirerEmail: "ada@x.org",
                          eventName: "Gala", performanceDate: "2026-05-01", venue: "V")
        inq.sentAt = Date(timeIntervalSince1970: 1_000)
        inq.gmailThreadId = threadId
        inq.gmailMessageId = "msg-1"
        return inq
    }

    @Test func aReplyOnTheInquiryThreadIsMarked() {
        let inq = sentInquiry()
        let entities: [any ReplyWatchable] = [inq]
        let n = ReplyService.detectReplies(in: entities, selfEmail: me,
                                           now: Date(timeIntervalSince1970: 9)) { _ in self.replyThread }
        #expect(n == 1)
        #expect(inq.replied == true)
        #expect(inq.repliedAt == Date(timeIntervalSince1970: 9))
    }

    @Test func aManuallyResolvedInquiryIsNeverOverwritten() {
        let inq = sentInquiry()
        inq.outcome = .lostSoft
        inq.outcomeSourceRaw = OutcomeSource.manual.rawValue
        let n = ReplyService.detectReplies(in: [inq], selfEmail: me, now: .now) { _ in self.replyThread }
        #expect(n == 0)
        #expect(inq.replied == false)
        #expect(inq.outcome == .lostSoft)
    }

    @Test func aBounceOnTheInquiryThreadIsMarked() {
        let inq = sentInquiry()
        let entities: [any ReplyWatchable] = [inq]
        BounceService.detectBounces(in: entities, selfEmail: me, now: .now) { _ in self.hardBounceJSON() }
        #expect(inq.bounced == true)
    }
}

// The live pipelines must actually FETCH inquiries, not just be capable of watching them. These
// drive the real GmailReplyChecker / reconcile entry points against a container that holds the full
// app schema, proving a logged inquiry is watched and reconciled in production, not only in a unit.
@MainActor
@Suite("Inquiry is watched by the live pipelines")
struct InquiryPipelineWiringTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema,
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func threadFetch(from: String) -> (URLRequest) async throws -> (Data, URLResponse) {
        let messages = [GmailFixture.Message(from: from)]
        return { req in inquiryGmail.respond(to: req, thread: messages) }
    }

    @Test func aReplyToALoggedInquiryIsDetectedByMarkReplies() async throws {
        let ctx = ModelContext(try container())
        let inq = Inquiry(source: .directEmail, inquirerName: "Ada", inquirerEmail: "ada@x.org",
                          eventName: "Gala", performanceDate: "2026-05-01", venue: "V")
        inq.sentAt = Date()
        inq.gmailThreadId = "inq-t1"
        inq.gmailMessageId = "m1"
        ctx.insert(inq)
        let checker = GmailReplyChecker(fromEmail: "dan@danwrightphotography.com")
        await checker.markReplies(in: ctx, token: "tok", now: Date(),
                                  fetch: threadFetch(from: "ada@x.org"))
        #expect(inq.replied == true)
    }
}

// Booking match for an inquiry: SUGGESTION-ONLY, never a silent auto-book, even on an exact match
// (#1435). But an inquiry still WINS the .exact tie-break over a competing prospect (#1434): a
// hand-logged inquiry is the stronger signal, so it claims the booking and the prospect drops to a
// suggestion rather than auto-booking.
@MainActor
@Suite("Inquiry booking match is suggestion-only and wins the tie-break")
struct InquiryBookingMatchTests {
    private func booking(client: String = "Ada Lovelace", id: String = "B1") -> OvertureBooking {
        OvertureBooking(id: id, clientId: "C1", clientDisplayName: client, shootName: "Gala",
                        startDate: "2026-05-01", endDate: "2026-05-01", venueId: nil, venueName: "V")
    }

    private func sentInquiry(name: String = "Ada Lovelace") -> Inquiry {
        let inq = Inquiry(source: .directEmail, inquirerName: name, inquirerEmail: "ada@x.org",
                          eventName: "Gala", performanceDate: "2026-05-01", venue: "V")
        inq.sentAt = Date(timeIntervalSince1970: 1_000)
        inq.gmailMessageId = "msg-inq"   // provably contacted
        return inq
    }

    private func sentProspect(_ ctx: ModelContext, group: String) -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "choral", venue: "V",
                         performanceDate: "2026-05-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved)
        p.sentAt = Date(timeIntervalSince1970: 1_000)
        p.gmailMessageId = "msg-\(group)"
        ctx.insert(p)
        return p
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // An exact booking match only SUGGESTS for an inquiry; it never flips the outcome to booked and
    // never counts as an auto-book.
    @Test func anExactBookingOnlySuggestsForAnInquiry() throws {
        let inq = sentInquiry()
        let entities: [any BookingMatchable] = [inq]
        let n = DownbeatBooking.reconcileBooked(entities: entities, clients: [], bookings: [booking()],
                                                health: .ok, now: Date(timeIntervalSince1970: 5_000))
        #expect(n == 0)
        #expect(inq.outcome == .noResponse)
        #expect(inq.bookingSuggested == true)
        #expect(inq.autoBookingRejectedWithoutId == false)
    }

    // Control: the SAME booking would auto-book a lone prospect. This is what the tie-break overrides.
    @Test func theSameBookingAutoBooksALoneProspect() throws {
        let ctx = ModelContext(try container())
        let p = sentProspect(ctx, group: "Ada Lovelace")
        let n = DownbeatBooking.reconcileBooked(entities: [p], clients: [], bookings: [booking()],
                                                health: .ok, now: Date(timeIntervalSince1970: 5_000))
        #expect(n == 1)
        #expect(p.outcome == .booked)
    }

    // Tie-break: when an inquiry and a prospect both match the same booking, the inquiry claims it and
    // the prospect is downgraded to a suggestion instead of auto-booking. Nobody auto-books.
    @Test func anInquiryWinsTheExactTieBreakOverAProspect() throws {
        let ctx = ModelContext(try container())
        let p = sentProspect(ctx, group: "Ada Lovelace")
        let inq = sentInquiry(name: "Ada Lovelace")
        let entities: [any BookingMatchable] = [p, inq]
        let n = DownbeatBooking.reconcileBooked(entities: entities, clients: [], bookings: [booking()],
                                                health: .ok, now: Date(timeIntervalSince1970: 5_000))
        #expect(n == 0)                       // nobody auto-booked
        #expect(p.outcome == .noResponse)     // prospect downgraded, not booked
        #expect(p.bookingSuggested == true)
        #expect(inq.outcome == .noResponse)   // inquiry never auto-books
        #expect(inq.bookingSuggested == true)
    }
}
