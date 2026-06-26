import Testing
import Foundation
@testable import Overture

// #196: the DEBUG-only staging helper that marks a prospect as already sent, so post-send
// flows (booking detection, follow-ups, reminders, reply handling) can be exercised without
// a live Gmail send. The helper itself is compiled out of release builds, so these tests
// (which always build in Debug) are the only thing that references it.
#if DEBUG
@Suite("Debug staging")
struct DebugStagingTests {
    private func makeProspect() -> Prospect {
        Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: nil,
                 performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "warm", production: "self", profile: "neutral",
                 coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
    }

    @Test func stagesAsApprovedAndSent() {
        let p = makeProspect()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        DebugStaging.stageAsSent(p, now: now)

        #expect(p.sentAt == now)
        #expect(p.status == .approved)
        // The two together are exactly what wasContacted keys off, so the lead now counts
        // as contacted for every post-send flow.
        #expect(p.wasContacted)
    }

    @Test func snapshotsPriorRelationshipLikeARealSend() {
        let p = makeProspect()

        DebugStaging.stageAsSent(p, now: Date())

        // Booking detection (#66) compares against the relationship captured at send time, so
        // the helper must mirror SendService and snapshot it.
        #expect(p.priorRelationshipAtSend == "warm")
    }

    @Test func leavesUnrelatedOutreachStateUntouched() {
        let p = makeProspect()
        p.draftBody = "hello"
        p.draftSubject = "subj"

        DebugStaging.stageAsSent(p, now: Date())

        // No spurious outcome, reply, or thread state: it stages a fresh send, nothing more.
        #expect(p.outcome == .noResponse)
        #expect(p.gmailThreadId == nil)
        #expect(p.gmailMessageId == nil)
        #expect(p.lastReplyText == nil)
        #expect(p.draftBody == "hello")
        #expect(p.draftSubject == "subj")
    }
}
#endif
