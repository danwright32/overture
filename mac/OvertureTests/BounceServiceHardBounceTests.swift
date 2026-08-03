import Testing
import Foundation

// #676: BounceServiceDelayDetectionTests (#656) only covers the delay-notice behavior added
// alongside the original hard-bounce path (#398). These tests exercise that original path
// directly: the outcomeSource/booked/already-bounced/already-replied/resolution guards, and the
// dismissedBounceId re-flag prevention.
@Suite("Bounce service hard bounce")
struct BounceServiceHardBounceTests {
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

    private static func hardBounceJSON(id: String = "bounce-1") -> Data {
        Data("""
        {"messages":[{"id":"\(id)","payload":{"headers":[
          {"name":"From","value":"mailer-daemon@googlemail.com"},
          {"name":"Subject","value":"Delivery Status Notification (Failure)"}
        ]}}]}
        """.utf8)
    }

    @Test @MainActor func aManualOutcomeSourceRecipientIsNeverFlagged() {
        let p = Self.prospectWithSentRecipient()
        let r = p.recipients[0]
        r.outcomeSource = .manual
        BounceService.detectBounces(in: [p], selfEmail: "dan@danwrightphotography.com", now: .now) { _ in Self.hardBounceJSON() }
        #expect(r.bounced == false)
    }

    @Test @MainActor func aManualOutcomeSourceProspectHasNoRecipientsFlagged() {
        let p = Self.prospectWithSentRecipient()
        p.outcomeSourceRaw = OutcomeSource.manual.rawValue
        BounceService.detectBounces(in: [p], selfEmail: "dan@danwrightphotography.com", now: .now) { _ in Self.hardBounceJSON() }
        #expect(p.recipients[0].bounced == false)
    }

    @Test @MainActor func aBookedShowIsSkipped() {
        let p = Self.prospectWithSentRecipient()
        p.outcome = .booked
        BounceService.detectBounces(in: [p], selfEmail: "dan@danwrightphotography.com", now: .now) { _ in Self.hardBounceJSON() }
        #expect(p.recipients[0].bounced == false)
    }

    @Test @MainActor func anAlreadyBouncedRecipientIsNotReprocessed() {
        let p = Self.prospectWithSentRecipient()
        let r = p.recipients[0]
        r.bounced = true
        r.lastBounceId = "earlier-bounce"
        BounceService.detectBounces(in: [p], selfEmail: "dan@danwrightphotography.com", now: .now) { _ in Self.hardBounceJSON(id: "bounce-2") }
        #expect(r.lastBounceId == "earlier-bounce")
    }

    @Test @MainActor func anAlreadyRepliedRecipientIsSkipped() {
        let p = Self.prospectWithSentRecipient()
        let r = p.recipients[0]
        r.replied = true
        BounceService.detectBounces(in: [p], selfEmail: "dan@danwrightphotography.com", now: .now) { _ in Self.hardBounceJSON() }
        #expect(r.bounced == false)
    }

    @Test @MainActor func aRecipientWithBookedResolutionIsSkipped() {
        let p = Self.prospectWithSentRecipient()
        let r = p.recipients[0]
        r.resolution = .booked
        BounceService.detectBounces(in: [p], selfEmail: "dan@danwrightphotography.com", now: .now) { _ in Self.hardBounceJSON() }
        #expect(r.bounced == false)
    }

    @Test @MainActor func aDismissedBounceIdDoesNotReFlag() {
        let p = Self.prospectWithSentRecipient()
        let r = p.recipients[0]
        r.dismissedBounceId = "bounce-1"
        BounceService.detectBounces(in: [p], selfEmail: "dan@danwrightphotography.com", now: .now) { _ in Self.hardBounceJSON(id: "bounce-1") }
        #expect(r.bounced == false)
        #expect(r.lastBounceId == nil)
    }

    @Test @MainActor func aGenuinelyNewBounceOnTheSameThreadStillFlags() {
        let p = Self.prospectWithSentRecipient()
        let r = p.recipients[0]
        r.dismissedBounceId = "bounce-1"
        let count = BounceService.detectBounces(in: [p], selfEmail: "dan@danwrightphotography.com", now: .now) { _ in Self.hardBounceJSON(id: "bounce-2") }
        #expect(r.bounced == true)
        #expect(r.lastBounceId == "bounce-2")
        #expect(count == 1)
    }
}
