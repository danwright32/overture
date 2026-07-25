import Testing
import Foundation
@testable import Overture

// Phase 2 (#1435): the follow-up nudge fires at 3 BUSINESS days of silence, so a Friday send isn't
// nagged on Monday. No business-day helper existed before this. Anchored on known weekdays:
// 2026-01-01 is a Thursday, so 01-02 Fri, 01-03 Sat, 01-04 Sun, 01-05 Mon, 01-06 Tue.
@Suite("Business day counting")
struct BusinessDayTests {
    private func date(_ day: String) -> Date { EasternDate.date(from: day)! }

    @Test func countsWeekdaysAfterTheStartThroughTheEnd() {
        // Thu 01-01 → Tue 01-06: Fri, Mon, Tue = 3 (Sat/Sun skipped).
        #expect(BusinessDay.count(after: date("2026-01-01"), through: date("2026-01-06")) == 3)
    }

    @Test func aWeekendDoesNotCount() {
        // Fri 01-02 → Mon 01-05: only Mon = 1.
        #expect(BusinessDay.count(after: date("2026-01-02"), through: date("2026-01-05")) == 1)
    }

    @Test func sameDayIsZero() {
        #expect(BusinessDay.count(after: date("2026-01-05"), through: date("2026-01-05")) == 0)
    }

    @Test func anEndBeforeTheStartIsZeroNeverNegative() {
        #expect(BusinessDay.count(after: date("2026-01-06"), through: date("2026-01-01")) == 0)
    }
}

@MainActor
@Suite("Inquiry follow-up nudge and closing suggestion")
struct InquiryNudgeTests {
    private func date(_ day: String) -> Date { EasternDate.date(from: day)! }

    private func sentInquiry() -> Inquiry {
        let inq = Inquiry(source: .directEmail, inquirerName: "Ada", inquirerEmail: "ada@x.org",
                          eventName: "Gala", performanceDate: "2026-05-01", venue: "V")
        inq.sentAt = date("2026-01-01")   // Thursday
        inq.gmailMessageId = "msg-1"
        return inq
    }

    @Test func nudgeIsNotDueBeforeThreeBusinessDays() {
        let inq = sentInquiry()
        // Mon 01-05 is only 2 business days after Thu 01-01 (Fri, Mon).
        #expect(inq.followUpNudgeDue(now: date("2026-01-05")) == false)
    }

    @Test func nudgeIsDueAtThreeBusinessDays() {
        let inq = sentInquiry()
        // Tue 01-06 is 3 business days after Thu 01-01.
        #expect(inq.followUpNudgeDue(now: date("2026-01-06")) == true)
    }

    @Test func aRepliedInquiryIsNeverNudged() {
        let inq = sentInquiry()
        inq.replied = true
        #expect(inq.followUpNudgeDue(now: date("2026-01-06")) == false)
    }

    @Test func anUnsentInquiryIsNeverNudged() {
        let inq = sentInquiry()
        inq.sentAt = nil
        inq.gmailMessageId = nil
        #expect(inq.followUpNudgeDue(now: date("2026-01-06")) == false)
    }

    @Test func aClosedInquiryIsNeitherNudgedNorSuggestedForClosing() {
        let inq = sentInquiry()
        inq.outcome = .lostSoft
        inq.outcomeSourceRaw = OutcomeSource.manual.rawValue
        #expect(inq.followUpNudgeDue(now: date("2026-03-01")) == false)
        #expect(inq.shouldSuggestClosing(now: date("2026-03-01")) == false)
    }

    @Test func closingIsSuggestedOnlyAfterLongSilence() {
        let inq = sentInquiry()
        // A few business days in: not yet.
        #expect(inq.shouldSuggestClosing(now: date("2026-01-08")) == false)
        // Two months of silence: yes.
        #expect(inq.shouldSuggestClosing(now: date("2026-03-01")) == true)
    }
}
