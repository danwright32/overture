import Testing
import Foundation
@testable import Overture

// Phase 3 (#1436): a hire inquiry flows through the queue's stages like a prospect (Dan's call,
// 2026-07-25), but only two apply. An inquiry Dan has not yet replied to needs to go out, so it sits
// in the to-send list (.sendApproved). Once he has sent the first reply and is awaiting a response, it
// moves to reached-out (.reachedOut), where the follow-up nudge lives. A booked or hand-lost inquiry
// is closed and belongs to no stage.
@MainActor
@Suite("Inquiry stage placement")
struct InquiryStageTests {
    private func inquiry() -> Inquiry {
        Inquiry(source: .directEmail, inquirerName: "Ada", inquirerEmail: "ada@x.org", eventName: "Gala")
    }

    @Test func anUnrepliedInquiryIsInTheToSendList() {
        #expect(StageNavigation.stage(for: inquiry()) == .sendApproved)
    }

    @Test func aRepliedInquiryMovesToReachedOut() {
        let inq = inquiry()
        inq.sentAt = Date()
        #expect(StageNavigation.stage(for: inq) == .reachedOut)
    }

    @Test func aBookedInquiryIsInNoStage() {
        let inq = inquiry()
        inq.outcome = .booked
        #expect(StageNavigation.stage(for: inq) == nil)
    }

    @Test func aHandLostInquiryIsInNoStage() {
        let inq = inquiry()
        inq.outcome = .lostSoft
        inq.outcomeSourceRaw = OutcomeSource.manual.rawValue
        #expect(StageNavigation.stage(for: inq) == nil)
    }
}
