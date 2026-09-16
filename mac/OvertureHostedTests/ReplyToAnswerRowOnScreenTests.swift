import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #3890: the Due list's row for a reply waiting on Dan's answer, as it is drawn.
//
// A row that only says somebody is waiting leaves Dan to go and find where the answer is written (#80,
// #126), so the row carries the Answer control itself, on scouted shows and hire inquiries alike, and
// names who wrote and how long ago so the oldest wait is readable at a glance.
@MainActor
@Suite("A reply waiting on an answer is a row with Answer on it (#3890)")
struct ReplyToAnswerRowOnScreenTests {
    private func day(_ s: String) -> Date { EasternDate.date(from: s)! }
    private var now: Date { day("2026-09-14").addingTimeInterval(10 * 3_600) }
    private var arrived: Date { now.addingTimeInterval(-2 * 3_600) }

    private func texts(_ view: some View) -> [String] {
        ((try? view.inspect().findAll(ViewType.Text.self)) ?? []).compactMap { try? $0.string() }
    }

    private func drawn(_ conversation: ReplyToAnswer.DueConversation) -> some View {
        FollowUpsView(prospects: [], inquiries: [])
            .replyToAnswerRow(conversation, sourceCalendars: [:], now: now)
    }

    @Test func aShowsRowNamesTheShowWhoWroteAndWhenAndOffersAnswer() throws {
        let p = Prospect(naturalKey: "k", groupName: "Every Voice Choirs", discipline: "choral",
                         venue: "Merkin Hall", performanceDate: "2026-10-31", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        let r = Recipient(id: "nicole@evc.example", email: "nicole@evc.example", name: "Nicole",
                          provenance: .presenter)
        r.sendState = .sent
        r.reopenOnReply(at: arrived)
        p.setRecipients([r])

        let row = drawn(.show(prospect: p, recipient: r))
        let lines = texts(row)
        #expect(lines.contains("Every Voice Choirs"))
        #expect(lines.contains(where: { $0.contains("Nicole") }))
        #expect(lines.contains(ReplyToAnswerCopy.line(arrivedAt: arrived, now: now)))
        #expect((try? row.inspect().find(button: ReplyPanelCopy.answer)) != nil,
                "the row says somebody is waiting and offers no way to answer them")
    }

    @Test func anInquirysRowNamesTheInquirerAndOffersAnswer() throws {
        let i = Inquiry(source: .contactForm, inquirerName: "Marta Reyes",
                        inquirerEmail: "marta@example.org", eventName: "Winter recital")
        i.replied = true
        i.repliedAt = arrived

        let row = drawn(.inquiry(i))
        let lines = texts(row)
        #expect(lines.contains("Marta Reyes"))
        #expect(lines.contains(where: { $0.contains("Winter recital") }))
        #expect(lines.contains("Contact form"), "the row does not say this is a hire inquiry")
        #expect(lines.contains(ReplyToAnswerCopy.line(arrivedAt: arrived, now: now)))
        #expect((try? row.inspect().find(button: ReplyPanelCopy.answer)) != nil)
    }

    // The wait is stated in words that change with it, so a reply from an hour ago and one from last
    // week do not read alike.
    @Test func theLineSaysHowLongAgoTheyWrote() {
        let line = ReplyToAnswerCopy.line(arrivedAt: arrived, now: now)
        #expect(line.contains("2 hours ago"), "got \(line)")
    }
}
