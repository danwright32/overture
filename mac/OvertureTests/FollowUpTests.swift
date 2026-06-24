import Testing
import Foundation
@testable import Overture

// #45: a gentle re-touch sequencer. Up to 2 nudges per lead, paced; auto-stops the moment
// the prospect replies or books. Nothing here sends — it only decides who is DUE and what
// the nudge says. The send stays an explicit click (Dan's hard rule).
@Suite("Follow-up sequencer")
struct FollowUpTests {
    private let day: TimeInterval = 86_400
    private let sent = Date(timeIntervalSince1970: 1_000_000)

    @Test func dueOnceTheGapHasPassedAfterTheSend() {
        let cfg = FollowUpConfig()  // 6-day gap, max 2
        #expect(FollowUp.isDue(sentAt: sent, lastFollowUpAt: nil, followUpCount: 0,
                               outcome: .noResponse, now: sent.addingTimeInterval(3 * day), config: cfg) == false)
        #expect(FollowUp.isDue(sentAt: sent, lastFollowUpAt: nil, followUpCount: 0,
                               outcome: .noResponse, now: sent.addingTimeInterval(7 * day), config: cfg) == true)
    }

    @Test func autoStopsOnReplyOrBooking() {
        let now = sent.addingTimeInterval(30 * day)
        #expect(FollowUp.isDue(sentAt: sent, lastFollowUpAt: nil, followUpCount: 0, outcome: .replied, now: now) == false)
        #expect(FollowUp.isDue(sentAt: sent, lastFollowUpAt: nil, followUpCount: 0, outcome: .booked, now: now) == false)
        #expect(FollowUp.isDue(sentAt: sent, lastFollowUpAt: nil, followUpCount: 0, outcome: .lostSoft, now: now) == false)
    }

    @Test func stopsAfterTwoNudges() {
        let now = sent.addingTimeInterval(60 * day)
        #expect(FollowUp.isDue(sentAt: sent, lastFollowUpAt: now.addingTimeInterval(-10 * day),
                               followUpCount: 2, outcome: .noResponse, now: now) == false)
    }

    @Test func pacesFromTheLastFollowUpNotTheOriginalSend() {
        let now = sent.addingTimeInterval(30 * day)
        // Last nudge was only 2 days ago -> not due yet, even though the send was long ago.
        #expect(FollowUp.isDue(sentAt: sent, lastFollowUpAt: now.addingTimeInterval(-2 * day),
                               followUpCount: 1, outcome: .noResponse, now: now) == false)
        // 7 days since the last nudge -> due.
        #expect(FollowUp.isDue(sentAt: sent, lastFollowUpAt: now.addingTimeInterval(-7 * day),
                               followUpCount: 1, outcome: .noResponse, now: now) == true)
    }

    @Test func nudgeBodyIsInVoiceAndUsesTheContactAndGroup() {
        let body = FollowUp.nudgeBody(contactName: "Emma Robinson", groupName: "Indianapolis Children's Choir", venue: "Carnegie Hall")
        #expect(body.contains("Emma"))
        #expect(body.contains("Indianapolis Children's Choir"))
        #expect(body.contains("—") == false)                       // no em dashes (brand voice)
        for banned in ["love to", "thrilled", "excited", "delighted", "can't wait", "!"] {
            #expect(body.lowercased().contains(banned) == false)   // no performative enthusiasm
        }
    }

    @Test func theFinalNudgeReadsDifferentlyAndSofter() {
        let first = FollowUp.nudgeBody(contactName: "Emma", groupName: "Acme Choir", venue: nil, attempt: 1)
        let final = FollowUp.nudgeBody(contactName: "Emma", groupName: "Acme Choir", venue: nil, attempt: 2)
        #expect(first != final)                                   // not a verbatim repeat
        #expect(final.contains("One last note"))                  // signals it's the last touch
        #expect(final.lowercased().contains("no need to reply"))  // soft, low-pressure close
        #expect(final.contains("—") == false)                     // still in voice
        for banned in ["love to", "thrilled", "excited", "!"] { #expect(final.lowercased().contains(banned) == false) }
    }

    @Test func nudgeGreetsGenericallyWhenNoContactName() {
        #expect(FollowUp.nudgeBody(contactName: nil, groupName: "The Dessoff Choirs", venue: nil).contains("Hi there"))
    }
}
