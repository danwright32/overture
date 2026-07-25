import Testing
import Foundation
@testable import Overture

// Phase 3 (#1436): a hire inquiry flows through the queue's stages like a prospect (Dan's call,
// 2026-07-25), but only two apply. An inquiry Dan has not yet replied to needs his action, so it sits
// in the Review stage (.review, a clickable pill Dan reaches, unlike .sendApproved which surfaces only
// in the masthead and has no navigable pill, #1436 walk finding). Once he has sent the first reply and
// is awaiting a response, it moves to reached-out (.reachedOut). A booked or hand-lost inquiry is
// closed and belongs to no stage.
@MainActor
@Suite("Inquiry stage placement")
struct InquiryStageTests {
    private func inquiry() -> Inquiry {
        Inquiry(source: .directEmail, inquirerName: "Ada", inquirerEmail: "ada@x.org", eventName: "Gala")
    }

    @Test func anUnrepliedInquiryIsInTheReviewStage() {
        #expect(StageNavigation.stage(for: inquiry()) == .review)
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

    // The stage pills must count inquiries too, or a logged inquiry would hide behind a pill that
    // reads "0" and Dan would never tap in. The count and the rows the tap lands on must agree.
    private func inputs(inquiries: [Inquiry]) -> AgentInputs {
        AgentInputs.from(prospects: [], inquiries: inquiries, now: Date(), today: "2026-07-01",
                         gmailConnected: true, prepRunning: false, replyRunAlive: false)
    }

    @Test func anUnrepliedInquiryAddsToTheReviewPill() {
        #expect(inputs(inquiries: [inquiry()]).toReview == 1)
    }

    @Test func aRepliedInquiryAddsToTheReachedOutPill() {
        let inq = inquiry()
        inq.sentAt = Date()
        #expect(inputs(inquiries: [inq]).reachedOut == 1)
    }

    @Test func aClosedInquiryAddsToNeitherPill() {
        let inq = inquiry()
        inq.outcome = .booked
        #expect(inputs(inquiries: [inq]).toReview == 0)
        #expect(inputs(inquiries: [inq]).reachedOut == 0)
    }
}
