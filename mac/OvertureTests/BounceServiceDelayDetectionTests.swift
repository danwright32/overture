import Testing
import Foundation


// #2928: the one Gmail fixture builder, at file scope.
private let delayDetectionGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com")
// #656: alongside the existing hard-bounce detection (#398), BounceService.detectBounces also
// notices a soft/temporary Gmail delay notice on the same already-fetched thread and records when
// it was first seen. Purely informational: never sets bounced, never touches isSilent or
// follow-up eligibility. A hard bounce still takes precedence when a thread somehow carries both.
@Suite("Bounce service delay detection")
struct BounceServiceDelayDetectionTests {
    @MainActor
    private static func prospectWithSentRecipient(threadId: String = "thread-1") -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted)
        let r = Recipient(id: "a@org.example", email: "a@org.example", provenance: .act)
        r.sendState = .sent
        r.gmailThreadId = threadId
        p.setRecipients([r])
        return p
    }

    private static func delayJSON(id: String = "delay-1") -> Data {
        delayDetectionGmail.thread([
            .init(from: "mailer-daemon@googlemail.com",
                  subject: "Delivery Status Notification (Delay)", id: id),
        ])
    }

    private static let hardBounceJSON = delayDetectionGmail.thread([
        .init(from: "mailer-daemon@googlemail.com",
              subject: "Delivery Status Notification (Failure)", id: "bounce-1"),
    ])

    @Test @MainActor func recordsWhenADelayNoticeWasFirstSeen() {
        let p = Self.prospectWithSentRecipient()
        let now = Date(timeIntervalSince1970: 1000)
        BounceService.detectBounces(in: [p], selfEmail: "dan@danwrightphotography.com", now: now) { _ in Self.delayJSON() }
        let r = p.recipients[0]
        #expect(r.delayNoticeAt == now)
        #expect(r.lastDelayMessageId == "delay-1")
        #expect(r.bounced == false)
    }

    @Test @MainActor func doesNotAdvanceTheTimestampForTheSameDelayNoticeOnALaterPass() {
        let p = Self.prospectWithSentRecipient()
        let first = Date(timeIntervalSince1970: 1000)
        BounceService.detectBounces(in: [p], selfEmail: "dan@danwrightphotography.com", now: first) { _ in Self.delayJSON() }
        let later = Date(timeIntervalSince1970: 5000)
        BounceService.detectBounces(in: [p], selfEmail: "dan@danwrightphotography.com", now: later) { _ in Self.delayJSON() }
        #expect(p.recipients[0].delayNoticeAt == first)
    }

    @Test @MainActor func aFreshDelayNoticeRestartsTheWindow() {
        let p = Self.prospectWithSentRecipient()
        let first = Date(timeIntervalSince1970: 1000)
        BounceService.detectBounces(in: [p], selfEmail: "dan@danwrightphotography.com", now: first) { _ in Self.delayJSON(id: "delay-1") }
        let later = Date(timeIntervalSince1970: 5000)
        BounceService.detectBounces(in: [p], selfEmail: "dan@danwrightphotography.com", now: later) { _ in Self.delayJSON(id: "delay-2") }
        let r = p.recipients[0]
        #expect(r.delayNoticeAt == later)
        #expect(r.lastDelayMessageId == "delay-2")
    }

    @Test @MainActor func aHardBounceTakesPrecedenceAndDoesNotAlsoSetADelayNotice() {
        let p = Self.prospectWithSentRecipient()
        let now = Date(timeIntervalSince1970: 1000)
        BounceService.detectBounces(in: [p], selfEmail: "dan@danwrightphotography.com", now: now) { _ in Self.hardBounceJSON }
        let r = p.recipients[0]
        #expect(r.bounced == true)
        #expect(r.delayNoticeAt == nil)
    }
}
