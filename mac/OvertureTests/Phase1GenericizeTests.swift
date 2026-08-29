import Testing
import Foundation
import SwiftData


// #2928: the one Gmail fixture builder, at file scope.
private let phase1Gmail = GmailFixture(selfEmail: "dan@danwrightphotography.com")
// Phase 1 (#1434): the reply/bounce/booking-match integration layer is genericized behind the
// `ReplyWatchable` and `BookingMatchable` protocols so a second entity type (Inquiry, #1435) can
// ride the SAME tested pipeline instead of a duplicated one. These tests drive the generic entry
// points THROUGH the protocol existential, not the concrete `Prospect` type, so they prove the
// protocol conformance actually reads and writes back through to the live `@Model` (Open Risk #1
// in the plan: a subtly wrong conformance silently gates an entity out of the pipeline, and the
// concrete-typed suites can't catch that). Behavior for `Prospect` is unchanged; those existing
// suites remain the untouched gate.
@MainActor
@Suite("Phase 1: genericized reply/bounce/booking-match")
struct Phase1GenericizeTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A provably-contacted prospect for "Acme Festival Chorus", matching booking B1 below.
    @discardableResult
    private func bookableProspect(_ ctx: ModelContext, group: String = "Acme Festival Chorus") -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved)
        p.sentAt = Date(timeIntervalSince1970: 1_000)
        p.gmailMessageId = "msg-\(group)"   // #963: a real send stamps a message id → wasProvablyContacted
        ctx.insert(p)
        return p
    }

    private func booking(id: String = "B1") -> OvertureBooking {
        OvertureBooking(id: id, clientId: "C1", clientDisplayName: "Acme Festival Chorus",
                        shootName: "Gala", startDate: "2026-07-01", endDate: "2026-07-01",
                        venueId: nil, venueName: "V")
    }

    // A prospect with one sent recipient carrying `threadId`, ready for reply/bounce detection.
    @discardableResult
    private func contactedProspect(_ ctx: ModelContext, threadId: String) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-08-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted)
        p.sentAt = Date(timeIntervalSince1970: 1_000)
        let r = Recipient(id: "a@org.example", email: "a@org.example", provenance: .act)
        r.sendState = .sent
        r.gmailThreadId = threadId
        p.setRecipients([r])
        ctx.insert(p)
        return p
    }

    private let me = "dan@danwrightphotography.com"
    private let replyThread = phase1Gmail.thread([.init(from: "dan@danwrightphotography.com"),
                                                  .init(from: "them@org.org")])
    private func hardBounceJSON(id: String = "bounce-1") -> Data {
        phase1Gmail.thread([
            .init(from: "mailer-daemon@googlemail.com",
                  subject: "Delivery Status Notification (Failure)", id: id),
        ])
    }

    // ── BookingMatchable ─────────────────────────────────────────────────────────

    @Test func aProspectClassifiesExactThroughTheGenericEntity() throws {
        let ctx = ModelContext(try container())
        let p = bookableProspect(ctx)
        let entity: any BookingMatchable = p
        #expect(BookingMatch.classify(entity: entity, bookings: [booking()]) == .exact(booking()))
    }

    @Test func aProspectBooksThroughTheGenericEntitiesEntry() throws {
        let ctx = ModelContext(try container())
        let p = bookableProspect(ctx)
        let entities: [any BookingMatchable] = [p]
        let n = DownbeatBooking.reconcileBooked(entities: entities, clients: [], bookings: [booking()],
                                                health: .ok, now: Date(timeIntervalSince1970: 5_000))
        #expect(n == 1)
        #expect(p.outcome == .booked)
        #expect(p.outcomeSourceRaw == OutcomeSource.auto.rawValue)
        #expect(p.autoBookedFromBookingId == "B1")
    }

    // The dual-attribution guard the whole genericization exists to make possible: ONE shared
    // `consumed` set across the WHOLE entity list means a single real booking is consumed exactly
    // once, even when two entities in the combined list both match it. (Phase 2 puts a Prospect and
    // an Inquiry in this list; here two prospects stand in.)
    @Test func oneBookingIsConsumedOnceAcrossTheCombinedEntityList() throws {
        let ctx = ModelContext(try container())
        let a = bookableProspect(ctx, group: "Acme Festival Chorus")
        let b = bookableProspect(ctx, group: "Acme Festival Chorus")
        let entities: [any BookingMatchable] = [a, b]
        let n = DownbeatBooking.reconcileBooked(entities: entities, clients: [], bookings: [booking()],
                                                health: .ok, now: Date(timeIntervalSince1970: 5_000))
        #expect(n == 1)
        let booked = [a, b].filter { $0.outcome == .booked }
        let suggested = [a, b].filter { $0.bookingSuggested }
        #expect(booked.count == 1)
        #expect(suggested.count == 1)
    }

    // ── ReplyWatchable ───────────────────────────────────────────────────────────

    @Test func aReplyIsMarkedThroughTheGenericReplyWatchableEntry() throws {
        let ctx = ModelContext(try container())
        let p = contactedProspect(ctx, threadId: "t1")
        let entities: [any ReplyWatchable] = [p]
        let n = ReplyService.detectReplies(in: entities, selfEmail: me,
                                           now: Date(timeIntervalSince1970: 9)) { _ in self.replyThread }
        #expect(n == 1)
        #expect(p.recipients.first?.replied == true)
    }

    @Test func aBounceIsMarkedThroughTheGenericReplyWatchableEntry() throws {
        let ctx = ModelContext(try container())
        let p = contactedProspect(ctx, threadId: "t1")
        let entities: [any ReplyWatchable] = [p]
        BounceService.detectBounces(in: entities, selfEmail: me, now: .now) { _ in self.hardBounceJSON() }
        #expect(p.recipients.first?.bounced == true)
    }
}
