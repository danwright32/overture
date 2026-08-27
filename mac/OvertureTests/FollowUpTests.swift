import Testing
import Foundation
import SwiftData

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

    // #610: "Hello," (Dan's preferred wording), not "Hi there,", when there's no contact name.
    @Test func nudgeGreetsGenericallyWhenNoContactName() {
        #expect(FollowUp.nudgeBody(contactName: nil, groupName: "The Dessoff Choirs", venue: nil).contains("Hello,"))
    }

    // #418 D — per-contact eligibility: the pacing core gates on an `eligible` flag.
    @Test func eligibleContactIsDueOnceTheGapPasses() {
        #expect(FollowUp.isDue(eligible: true, sentAt: sent, lastFollowUpAt: nil, followUpCount: 0,
                               now: sent.addingTimeInterval(7 * day)) == true)
        #expect(FollowUp.isDue(eligible: false, sentAt: sent, lastFollowUpAt: nil, followUpCount: 0,
                               now: sent.addingTimeInterval(7 * day)) == false)   // not eligible -> never due
    }

    @MainActor
    @Test func dueRecipientsPicksOnlySilentUnresolvedContacts() throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .contacted)
        p.sentAt = sent
        ctx.insert(p)
        let silent = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        silent.sendState = .sent; silent.sentAt = sent
        let replied = Recipient(id: "b@p.example", email: "b@p.example", provenance: .presenter)
        replied.sendState = .sent; replied.sentAt = sent; replied.replied = true
        let closed = Recipient(id: "c@m.example", email: "c@m.example", provenance: .manual)
        closed.sendState = .sent; closed.sentAt = sent; closed.markOutcomeManually(resolution: .declinedSoft)
        p.setRecipients([silent, replied, closed])

        let due = FollowUp.dueRecipients(from: [p], now: sent.addingTimeInterval(10 * day))
        #expect(due.map(\.recipient.id) == ["a@act.example"])   // only the silent, un-resolved, gap-passed one
    }

    @MainActor
    @Test func dueRecipientsExcludesABookedShow() throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .contacted)
        p.sentAt = sent; p.outcome = .booked
        ctx.insert(p)
        let silent = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        silent.sendState = .sent; silent.sentAt = sent
        p.setRecipients([silent])
        #expect(FollowUp.dueRecipients(from: [p], now: sent.addingTimeInterval(10 * day)).isEmpty)
    }

    @Test func replySubjectPrefixesReExactlyOnceWithAFallback() {
        // #74: thread under the original subject; never stack "Re: Re:"; fall back if missing.
        #expect(FollowUp.replySubject(originalSubject: "Photographing your recital", groupName: "X")
                == "Re: Photographing your recital")
        #expect(FollowUp.replySubject(originalSubject: "Re: Already a reply", groupName: "X")
                == "Re: Already a reply")
        #expect(FollowUp.replySubject(originalSubject: nil, groupName: "Dessoff Choirs")
                == "Re: Following up: photographs for Dessoff Choirs")
    }
}
