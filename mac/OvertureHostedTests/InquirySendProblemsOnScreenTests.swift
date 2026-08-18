import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #2675: the send problems reaching the SCREEN, which is a separate claim from the row carrying them
// (L3). That gap is the whole issue: all three facts had writers, the flags were correct, and nothing
// anywhere in the app drew any of them.
@MainActor
@Suite("An inquiry's send problems on screen (#2675)")
struct InquirySendProblemsOnScreenTests {

    private func row(threadIdDegraded: Bool = false, threadingDegraded: Bool = false,
                     sendError: String? = nil) -> InquiryRow {
        InquiryRow(id: "i1", inquirerName: "Nora Vance", source: .contactForm,
                   eventName: "A recital", performanceDate: "2026-09-12", venue: "Weill Recital Hall",
                   outcome: .noResponse, sentAt: Date(), replied: false, hasUnhandledReply: false,
                   answeredReplyLine: nil, bounced: false,
                   bookingSuggested: false, followUpNudgeDue: false, shouldSuggestClosing: false,
                   threadIdDegraded: threadIdDegraded, threadingDegraded: threadingDegraded,
                   sendError: sendError)
    }

    // The sentences actually drawn. Help text is a tooltip, not a mark on the page, so it is excluded:
    // this suite is about what Dan can SEE without hovering, which is what a badge is for (L49).
    private func lines(_ row: InquiryRow) -> [String] {
        let view = InquiryRowView(row: row, onReply: {}, onEdit: {}, onMarkBooked: {}, onMarkLost: { _ in })
        let all = ((try? view.inspect().findAll(ViewType.Text.self)) ?? []).compactMap { try? $0.string() }
        let helps: Set<String> = [InquiryCopy.replyTrackingLostHelp, InquiryCopy.threadingDegradedHelp]
        return all.filter { !helps.contains($0) && !$0.isEmpty }
    }

    // The ordinary inquiry, which is every one on the live store today. Nothing about a send problem may
    // appear, or every healthy row grows a warning it does not deserve.
    @Test func aHealthyInquiryDrawsNoneOfThem() {
        let drawn = lines(row())
        #expect(!drawn.contains(InquiryCopy.replyTrackingLostBadge))
        #expect(!drawn.contains(InquiryCopy.threadingDegradedBadge))
        #expect(!drawn.contains { $0.hasPrefix("Send failed") })
    }

    @Test func aLostThreadIsOnScreenInItsOwnWords() {
        #expect(lines(row(threadIdDegraded: true)).contains(InquiryCopy.replyTrackingLostBadge))
    }

    @Test func aLostMessageIdIsOnScreenInItsOwnWords() {
        #expect(lines(row(threadingDegraded: true)).contains(InquiryCopy.threadingDegradedBadge))
    }

    // The reason the send gave, in full, because a badge cannot carry it and a failure with no reason is
    // the thing Dan can do least about.
    @Test func aFailedSendPrintsTheReasonItGave() {
        #expect(lines(row(sendError: "Gmail refused the message"))
            .contains("Send failed: Gmail refused the message"))
    }

    // All three at once, which is a state one send can genuinely produce: they are independent checks and
    // one must not hide another (L53).
    @Test func allThreeCanBeOnScreenTogether() {
        let drawn = lines(row(threadIdDegraded: true, threadingDegraded: true,
                              sendError: "Gmail refused the message"))
        #expect(drawn.contains(InquiryCopy.replyTrackingLostBadge))
        #expect(drawn.contains(InquiryCopy.threadingDegradedBadge))
        #expect(drawn.contains("Send failed: Gmail refused the message"))
    }

    // And the row keeps saying everything it said before, so the new line is an addition rather than a
    // replacement for the state Dan already reads.
    @Test func theRowStillSaysWhoAndWhatItAlwaysDid() {
        let drawn = lines(row(threadIdDegraded: true))
        #expect(drawn.contains("Nora Vance"))
        #expect(drawn.contains(InquiryCopy.rowState(sentAt: Date(), replied: false, answeredReplyLine: nil)))
    }
}
